package com.viam.ble

import android.annotation.SuppressLint
import android.bluetooth.BluetoothDevice
import android.bluetooth.BluetoothGatt
import android.bluetooth.BluetoothGattCallback
import android.bluetooth.BluetoothGattCharacteristic
import android.bluetooth.BluetoothGattCharacteristic.WRITE_TYPE_DEFAULT
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
import java.util.concurrent.TimeoutException
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

    @SuppressLint("MissingPermission")
    fun writeCharacteristic(
        serviceId: String,
        charId: String,
        data: ByteArray,
    ): Boolean {
        val svcUUID = UUID.fromString(serviceId)
        val charUUID = UUID.fromString(charId)
        val svc = gatt?.getService(svcUUID) ?: throw Exception("service $serviceId not found")
        val char = svc.getCharacteristic(charUUID) ?: throw Exception("characteristic $charId not found")
        char.setValue(data)
        char.writeType = WRITE_TYPE_DEFAULT
        return gatt?.writeCharacteristic(char) ?: throw Exception("gatt not available")
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
                Log.d(TAG, "onConnectionStateChange status: $status state: $newState device: ${device.name} ${device.address}")
                if (newState == BluetoothProfile.STATE_CONNECTED) {
                    requireNotNull(gatt)
                    gatt.discoverServices()
                } else {
                    disconnected = true
                    val exceptionStr = "failed to connect to device: ${device.name} ${device.address} with GATT status: $status state: $newState"
                    // 147 corresponds to GATT_CONNECTION_TIMEOUT but that was introduced in API level 35, so doing a straight
                    // comparison instead.
                    if (status == 147) {
                        connectedContinuation?.resumeWithException(TimeoutException(exceptionStr))
                    } else {
                        connectedContinuation?.resumeWithException(Exception(exceptionStr))
                    }
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
                if (status == BluetoothGatt.GATT_SUCCESS && gatt != null) {
                    val charsToRead =
                        gatt.services?.flatMap { svc ->
                            svc.characteristics.filter filter@{ char ->
                                if (char.properties and BluetoothGattCharacteristic.PROPERTY_READ != 0) {
                                    return@filter true
                                }
                                val charUUID = char.uuid.toString().lowercase()
                                val charSvcUUID =
                                    char.service.uuid
                                        .toString()
                                        .lowercase()
                                if (!discoveredCharacteristics.containsKey(charSvcUUID)) {
                                    discoveredCharacteristics[charSvcUUID] = mutableSetOf()
                                }
                                discoveredCharacteristics[charSvcUUID]?.add(charUUID)

                                return@filter false
                            }
                        }
                    neededCharDoneCount = charsToRead?.size ?: 0
                    if (neededCharDoneCount == 0) {
                        serviceDiscoveryDone(gatt)
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

            fun serviceDiscoveryDone(gatt: BluetoothGatt) {
                _discoveredServices =
                    gatt.services
                        .filter { discoveredCharacteristics.containsKey(it.uuid.toString().lowercase()) }
                        .map { svc ->
                            hashMapOf(
                                "id" to svc.uuid.toString().lowercase(),
                                "characteristics" to
                                    svc.characteristics
                                        .filter {
                                            discoveredCharacteristics[
                                                it.service.uuid
                                                    .toString()
                                                    .lowercase(),
                                            ]!!.contains(
                                                it.uuid.toString().lowercase(),
                                            )
                                        }.map { char ->
                                            hashMapOf(
                                                "id" to char.uuid.toString().lowercase(),
                                            )
                                        },
                            )
                        }
                connectedContinuation?.resume(Unit)
                connectedContinuation = null
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
                val charUUID = characteristic.uuid.toString().lowercase()
                val charSvcUUID =
                    characteristic.service.uuid
                        .toString()
                        .lowercase()
                if (status != BluetoothGatt.GATT_SUCCESS) {
                    Log.d(TAG, "error getting characteristic $charUUID: $status")
                } else {
                    if (!discoveredCharacteristics.containsKey(charSvcUUID)) {
                        discoveredCharacteristics[charSvcUUID] = mutableSetOf()
                    }
                    discoveredCharacteristics[charSvcUUID]?.add(charUUID)
                }
                if (discoveredSvcDoneCount == neededCharDoneCount) {
                    serviceDiscoveryDone(gatt)
                }
            }
        }
}
