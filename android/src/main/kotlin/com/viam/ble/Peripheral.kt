package com.viam.ble

import android.bluetooth.BluetoothDevice
import android.bluetooth.BluetoothGatt
import android.bluetooth.BluetoothGattCallback
import android.bluetooth.BluetoothGattCharacteristic
import android.bluetooth.BluetoothManager
import android.bluetooth.BluetoothProfile
import android.content.Context
import android.util.Log
import com.viam.ble.BlePlugin.Companion.TAG
import kotlinx.coroutines.CancellableContinuation
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.delay
import kotlinx.coroutines.launch
import kotlinx.coroutines.suspendCancellableCoroutine
import kotlinx.coroutines.sync.Mutex
import kotlinx.coroutines.sync.withLock
import kotlinx.coroutines.withContext
import java.util.UUID
import kotlin.coroutines.resume
import kotlin.coroutines.resumeWithException

class Peripheral(
    private val btMan: BluetoothManager,
    macAddress: String,
) {
    private val device: BluetoothDevice = btMan.adapter.getRemoteDevice(macAddress)
    private var channels: MutableMap<Int, L2CAPChannelManager> = mutableMapOf()
    private val channelsMutex = Mutex()

    @Volatile
    private var isClosed = false

    @Volatile
    private var connectedContinuation: CancellableContinuation<Unit>? = null

    @Volatile
    private var disconnectedContinuation: CancellableContinuation<Unit>? = null

    @Volatile
    private var _discoveredServices: List<Map<String, Any>> = mutableListOf()

    private var discoveredCharacteristics: MutableMap<String, MutableSet<String>> = mutableMapOf()
    val discoveredServices: List<Map<String, Any>>
        get() = _discoveredServices
    private var gatt: BluetoothGatt? = null

    @Throws(SecurityException::class)
    suspend fun connect(
        context: Context,
        connectedContinuation: CancellableContinuation<Unit>,
    ) {
        if (this.connectedContinuation != null) {
            throw Exception("already connecting")
        }
        this.connectedContinuation = connectedContinuation
        // Specifying BluetoothDevice.TRANSPORT_LE and waiting about 100ms seems to not error
        // with the undocumented status 133
        delay(200)
        gatt = device.connectGatt(context, false, bluetoothGattCallback, BluetoothDevice.TRANSPORT_LE)
    }

    @Throws(SecurityException::class)
    suspend fun connectToL2CAPChannel(psm: Int): Int {
        val socket = device.createL2capChannel(psm)
        withContext(Dispatchers.IO) {
            socket.connect()
            // delay after each op to avoid errors
            delay(100)
        }
        channelsMutex.withLock {
            var chansForPSM = channels[psm]
            if (chansForPSM == null) {
                chansForPSM = L2CAPChannelManager()
                channels[psm] = chansForPSM
            }
            return chansForPSM.handleNewChannel(socket)
        }
    }

    suspend fun getChannel(
        psm: Int,
        cid: Int,
    ): L2CAPChannel? {
        return withContext(Dispatchers.IO) {
            channelsMutex.withLock {
                return@withContext channels[psm]?.getChannel(cid)
            }
        }
    }

    fun readCharacteristic(
        serviceId: String,
        charId: String,
    ): ByteArray {
        val svcUUID = UUID.fromString(serviceId)
        val charUUID = UUID.fromString(charId)
        val svc = gatt?.getService(svcUUID) ?: throw Exception("service $serviceId not found")
        val char = svc.getCharacteristic(charUUID) ?: throw Exception("characteristic $charId not found")
        @Suppress("DEPRECATION")
        return char.value ?: throw Exception("characteristic $charId not yet read")
    }

    @Throws(SecurityException::class)
    suspend fun close() {
        if (isClosed) {
            return
        }
        isClosed = true

        // guarded by isClosed volatile
        closeOnDisconnect(true)
        withContext(Dispatchers.IO) {
            if (!(
                    gatt == null ||
                        btMan.getConnectionState(device, BluetoothProfile.GATT) == BluetoothProfile.STATE_DISCONNECTED
                )
            ) {
                suspendCancellableCoroutine { cont ->
                    disconnectedContinuation = cont
                    gatt?.disconnect()
                    if (bluetoothGattCallback.disconnected) {
                        cont.resume(Unit)
                    }
                }
            }
            gatt?.close()
        }
    }

    @Throws(SecurityException::class)
    suspend fun closeOnDisconnect(wasRequested: Boolean) {
        val exception =
            if (wasRequested) {
                Exception("peripheral closing")
            } else {
                Exception("peripheral disconnected")
            }
        withContext(Dispatchers.IO) {
            connectedContinuation?.resumeWithException(exception)
            connectedContinuation = null
            val readCopy =
                channelsMutex.withLock {
                    val copy = channels.values.toList()
                    channels.clear()
                    return@withLock copy
                }
            readCopy.forEach {
                it.close()
            }
        }
    }

    private val bluetoothGattCallback =
        object : BluetoothGattCallback() {
            private var neededCharDoneCount = 0
            private var discoveredSvcDoneCount = 0
            private var currentCharCont: CancellableContinuation<Unit>? = null

            @Volatile
            var disconnected = false

            @Throws(SecurityException::class)
            override fun onConnectionStateChange(
                gatt: BluetoothGatt?,
                status: Int,
                newState: Int,
            ) {
                Log.d(TAG, "onConnectionStateChange $status $newState")
                if (newState == BluetoothProfile.STATE_CONNECTED) {
                    requireNotNull(gatt)
                    gatt.discoverServices()
                } else {
                    disconnected = true
                    connectedContinuation?.resumeWithException(Exception("failed to connect with GATT status: $status state: $newState"))
                    connectedContinuation = null
                    val disconnectRequested = disconnectedContinuation != null
                    disconnectedContinuation?.resume(Unit)
                    disconnectedContinuation = null
                    if (!disconnectRequested) {
                        // fire this off
                        CoroutineScope(Dispatchers.IO).launch {
                            closeOnDisconnect(false)
                        }
                    }
                }
            }

            @Throws(SecurityException::class)
            override fun onServicesDiscovered(
                gatt: BluetoothGatt?,
                status: Int,
            ) {
                if (status == BluetoothGatt.GATT_SUCCESS) {
                    val charsToRead =
                        gatt?.services?.flatMap { svc ->
                            svc.characteristics.filter { char ->
                                char.properties and BluetoothGattCharacteristic.PROPERTY_READ != 0
                            }
                        }
                    neededCharDoneCount = charsToRead?.size ?: 0
                    if (neededCharDoneCount == 0) {
                        connectedContinuation?.resume(Unit)
                        connectedContinuation = null
                        return
                    }
                    CoroutineScope(Dispatchers.IO).launch {
                        charsToRead?.forEach {
                            suspendCancellableCoroutine { charCont ->
                                currentCharCont = charCont
                                gatt.readCharacteristic(it)
                            }
                            // delay after each op to avoid errors
                            delay(100)
                        }
                    }
                } else {
                    Log.e(TAG, "onServicesDiscovered received: $status")
                }
            }

            @Deprecated("Deprecated in Java")
            override fun onCharacteristicRead(
                gatt: BluetoothGatt,
                characteristic: BluetoothGattCharacteristic,
                status: Int,
            ) {
                currentCharCont?.resume(Unit)
                currentCharCont = null
                discoveredSvcDoneCount++
                if (status != BluetoothGatt.GATT_SUCCESS) {
                    Log.d(TAG, "error getting characteristic ${characteristic.uuid}: $status")
                } else {
                    if (!discoveredCharacteristics.containsKey(characteristic.service.uuid.toString())) {
                        discoveredCharacteristics[characteristic.service.uuid.toString()] = mutableSetOf()
                    }
                    discoveredCharacteristics[characteristic.service.uuid.toString()]?.add(characteristic.uuid.toString())
                }
                if (discoveredSvcDoneCount == neededCharDoneCount) {
                    _discoveredServices =
                        gatt.services
                            .filter { discoveredCharacteristics.containsKey(it.uuid.toString()) }
                            .map { svc ->
                                hashMapOf(
                                    "id" to svc.uuid.toString(),
                                    "characteristics" to
                                        svc.characteristics
                                            .filter { discoveredCharacteristics[it.service.uuid.toString()]!!.contains(it.uuid.toString()) }
                                            .map { char ->
                                                hashMapOf(
                                                    "id" to char.uuid.toString(),
                                                )
                                            },
                                )
                            }
                    connectedContinuation?.resume(Unit)
                    connectedContinuation = null
                }
            }
        }
}
