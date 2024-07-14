package com.viam.ble

import android.annotation.SuppressLint
import android.bluetooth.BluetoothAdapter
import android.bluetooth.BluetoothDevice
import android.bluetooth.BluetoothGattCharacteristic
import android.bluetooth.BluetoothGattServer
import android.bluetooth.BluetoothGattServerCallback
import android.bluetooth.BluetoothGattService
import android.bluetooth.le.AdvertiseCallback
import android.bluetooth.le.AdvertiseData
import android.bluetooth.le.AdvertiseSettings
import android.bluetooth.le.BluetoothLeAdvertiser
import android.content.Context
import android.os.ParcelUuid
import android.util.Log
import com.viam.ble.BlePlugin.Companion.TAG
import kotlinx.coroutines.CancellableContinuation
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.launch
import kotlinx.coroutines.suspendCancellableCoroutine
import kotlinx.coroutines.sync.Mutex
import kotlinx.coroutines.sync.withLock
import kotlinx.coroutines.withContext
import java.lang.ref.WeakReference
import java.util.UUID
import kotlin.coroutines.resume
import kotlin.coroutines.resumeWithException

// PeripheralManager is our Android based BLE Peripheral manager.
// It is a singleton so that we don't double up on any bluetooth operations that would cause an
// incorrect or unexpected program state.
@SuppressLint("MissingPermission")
class PeripheralManager(
    context: WeakReference<Context>,
) : BluetoothManager(context) {
    private val advertiser: BluetoothLeAdvertiser by lazy {
        val adv =
            btMan.adapter.bluetoothLeAdvertiser
                ?: throw Exception("either bluetooth is turned off or multi advertisement not supported")
        return@lazy adv
    }
    private val gatt: BluetoothGattServer by lazy { btMan.openGattServer(context.get(), this.gattServerCallback) }
    private var channels: MutableMap<Int, L2CAPChannelManager> = mutableMapOf()
    private val channelsMutex = Mutex()
    private val servicesToAdvertise: MutableList<BluetoothGattService> = mutableListOf()
    private val charsToAdvertise: MutableMap<UUID, ByteArray> = mutableMapOf()
    private val servicesMutex = Mutex()

    @Volatile
    private var addServiceCont: CancellableContinuation<Unit>? = null

    @Volatile
    private var startAdvertisingCont: CancellableContinuation<Unit>? = null

    @Throws(SecurityException::class)
    suspend fun reset() {
        withContext(Dispatchers.IO) {
            if (state == BluetoothAdapter.STATE_ON) {
                advertiser.stopAdvertising(advertiseCallback)
                gatt.clearServices()
            }
            servicesMutex.withLock {
                servicesToAdvertise.clear()
                charsToAdvertise.clear()
            }
            channelsMutex.withLock {
                channels.values.forEach {
                    it.close()
                }
                channels.clear()
            }
        }
    }

    suspend fun publishChannel(): Int {
        mustBePoweredOn()
        return withContext(Dispatchers.IO) {
            val serverSocket = btMan.adapter.listenUsingL2capChannel()
            val psm = serverSocket.psm
            channelsMutex.withLock {
                channels[psm] = L2CAPChannelManager(serverSocket)
            }
            CoroutineScope(Dispatchers.IO).launch {
                try {
                    while (true) {
                        val socket = serverSocket.accept()
                        channelsMutex.withLock {
                            if (channels[psm] == null) {
                                // disconnected/closed
                                Log.d(TAG, "accepted socket but server disconnected")
                                return@launch
                            }
                            channels[psm]!!.handleNewChannel(socket)
                        }
                    }
                } catch (e: Throwable) {
                    Log.d(TAG, "exception accepting socket for ${serverSocket.psm}: $e")
                }
            }
            return@withContext psm
        }
    }

    suspend fun unpublishChannel(psm: Int) {
        mustBePoweredOn()
        return withContext(Dispatchers.IO) {
            channelsMutex.withLock {
                val chansForPSM = channels[psm] ?: return@withContext
                chansForPSM.close()
                channels.remove(psm)
                return@withContext
            }
        }
    }

    suspend fun addService(
        svcTypeUUID: UUID,
        charDescs: Map<String, String>,
    ) {
        mustBePoweredOn()

        val svc = BluetoothGattService(svcTypeUUID, BluetoothGattService.SERVICE_TYPE_PRIMARY)
        val charVals = mutableMapOf<UUID, ByteArray>()
        charDescs.forEach {
            val charTypeUUID = UUID.fromString(it.key)!!
            val char =
                BluetoothGattCharacteristic(
                    charTypeUUID,
                    BluetoothGattCharacteristic.PROPERTY_READ,
                    BluetoothGattCharacteristic.PERMISSION_READ,
                )
            svc.addCharacteristic(char)
            charVals[charTypeUUID] = it.value.toByteArray()
        }

        servicesMutex.withLock {
            val existingIndex =
                servicesToAdvertise.indexOfFirst {
                    it.uuid == svc.uuid
                }
            if (existingIndex != -1) {
                val existingSvc = servicesToAdvertise[existingIndex]
                existingSvc.characteristics.forEach {
                    charsToAdvertise.remove(it.uuid)
                }
                gatt.removeService(existingSvc)
                servicesToAdvertise.removeAt(existingIndex)
            }
            svc.characteristics.forEach { newChar ->
                if (servicesToAdvertise.firstOrNull {
                        it.characteristics.firstOrNull { existingChar -> newChar.uuid == existingChar.uuid } != null
                    } != null
                ) {
                    throw Exception("characteristic ${newChar.uuid} is already present in another service")
                }
                charsToAdvertise[newChar.uuid] = charVals[newChar.uuid]!!
            }
            suspendCancellableCoroutine { cont ->
                addServiceCont = cont
                gatt.addService(svc)
            }
            servicesToAdvertise.add(svc)
        }
    }

    suspend fun startAdvertising(withName: String) {
        mustBePoweredOn()
        if (withName.isNotEmpty()) {
            btMan.adapter.setName(withName)
        }
        val settings =
            AdvertiseSettings
                .Builder()
                .setAdvertiseMode(AdvertiseSettings.ADVERTISE_MODE_LOW_LATENCY)
                .setConnectable(true)
                .setTxPowerLevel(AdvertiseSettings.ADVERTISE_TX_POWER_HIGH)
                .build()
        val dataBuilder = AdvertiseData.Builder()
        servicesMutex.withLock {
            servicesToAdvertise.forEach {
                dataBuilder.addServiceUuid(ParcelUuid(it.uuid))
            }
        }

        val scanResponse = AdvertiseData.Builder().setIncludeDeviceName(true).build()

        suspendCancellableCoroutine { cont ->
            startAdvertisingCont = cont
            advertiser.startAdvertising(settings, dataBuilder.build(), scanResponse, advertiseCallback)
        }
    }

    suspend fun getChannelManager(psm: Int): L2CAPChannelManager? {
        mustBePoweredOn()
        return withContext(Dispatchers.IO) {
            channelsMutex.withLock {
                return@withContext channels[psm]
            }
        }
    }

    suspend fun getChannel(
        psm: Int,
        cid: Int,
    ): L2CAPChannel? {
        mustBePoweredOn()
        return withContext(Dispatchers.IO) {
            channelsMutex.withLock {
                return@withContext channels[psm]?.getChannel(cid)
            }
        }
    }

    private val advertiseCallback: AdvertiseCallback =
        object : AdvertiseCallback() {
            override fun onStartSuccess(settingsInEffect: AdvertiseSettings?) {
                startAdvertisingCont?.resume(Unit)
                startAdvertisingCont = null
            }

            override fun onStartFailure(errorCode: Int) {
                startAdvertisingCont?.resumeWithException(Exception("advertise onStartFailure: $errorCode"))
                startAdvertisingCont = null
            }
        }

    private val gattServerCallback: BluetoothGattServerCallback =
        object : BluetoothGattServerCallback() {
            override fun onServiceAdded(
                status: Int,
                service: BluetoothGattService?,
            ) {
                super.onServiceAdded(status, service)
                addServiceCont?.resume(Unit)
                addServiceCont = null
            }

            override fun onCharacteristicReadRequest(
                device: BluetoothDevice?,
                requestId: Int,
                offset: Int,
                characteristic: BluetoothGattCharacteristic?,
            ) {
                super.onCharacteristicReadRequest(device, requestId, offset, characteristic)
                if (device == null) {
                    return
                }
                if (characteristic == null) {
                    CoroutineScope(Dispatchers.IO).launch {
                        gatt.sendResponse(device, requestId, 0x7fffffff, 0, ByteArray(0))
                    }
                    return
                }
                CoroutineScope(Dispatchers.IO).launch {
                    servicesMutex.withLock {
                        val charValue = charsToAdvertise[characteristic.uuid]
                        CoroutineScope(Dispatchers.IO).launch {
                            gatt.sendResponse(device, requestId, 0, 0, charValue)
                        }
                    }
                }
            }
        }
}
