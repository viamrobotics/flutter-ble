package com.viam.ble

import android.bluetooth.BluetoothAdapter
import android.bluetooth.BluetoothGattCharacteristic
import android.bluetooth.BluetoothGattService
import android.util.Log
import com.viam.ble.BlePlugin.Companion.CENTRAL_MANAGER_SCAN_FOR_PERIPHERALS_NOTIFICATION_NAME
import com.viam.ble.BlePlugin.Companion.PSM_PARAM_NAME
import io.flutter.embedding.engine.plugins.FlutterPlugin
import io.flutter.plugin.common.EventChannel
import io.flutter.plugin.common.EventChannel.EventSink
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel
import io.flutter.plugin.common.MethodChannel.MethodCallHandler
import io.flutter.plugin.common.MethodChannel.Result
import kotlinx.coroutines.CoroutineExceptionHandler
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.cancel
import kotlinx.coroutines.flow.takeWhile
import kotlinx.coroutines.isActive
import kotlinx.coroutines.launch
import kotlinx.coroutines.sync.Mutex
import kotlinx.coroutines.sync.withLock
import org.json.JSONObject
import java.lang.ref.WeakReference
import java.util.UUID

// BlePlugin is the entry point for Flutter into the Android platform. It provides access to the CentralManager and PeripheralManager.
class BlePlugin :
    FlutterPlugin,
    MethodCallHandler {
    private lateinit var channel: MethodChannel

    private lateinit var centralManager: CentralManager
    private lateinit var peripheralManager: PeripheralManager

    companion object {
        const val TAG = "BlePlugin"
        const val CENTRAL_MANAGER_SCAN_FOR_PERIPHERALS_NOTIFICATION_NAME = "centralManagerScanForPeripherals"
        const val CENTRAL_MANAGER_GET_STATE_NOTIFICATION_NAME = "centralManagerGetState"
        const val PERIPHERAL_MANAGER_GET_STATE_NOTIFICATION_NAME = "peripheralManagerGetState"
        const val PERIPHERAL_MANAGER_CHANNEL_OPENED_NOTIFICATION_NAME = "peripheralManagerChannelOpened"
        const val DEVICE_ID_PARAM_NAME = "device_id" // on android, really a MAC address
        const val SERVICE_ID_PARAM_NAME = "service_id"
        const val CHARACTERISTIC_ID_PARAM_NAME = "characteristic_id"
        const val PSM_PARAM_NAME = "psm"
        const val CID_PARAM_NAME = "cid"
        const val DATA_PARAM_NAME = "data"
        const val MAX_READ_PARAM_NAME = "max_read"
        const val UUID_PARAM_NAME = "uuid"
        const val CHARACTERISTICS_PARAM_NAME = "characteristics"
        const val NAME_PARAM_NAME = "name"
    }

    override fun onAttachedToEngine(flutterPluginBinding: FlutterPlugin.FlutterPluginBinding) {
        channel = MethodChannel(flutterPluginBinding.binaryMessenger, "ble")
        channel.setMethodCallHandler(this)
        centralManager = CentralManager(WeakReference(flutterPluginBinding.applicationContext))
        peripheralManager = PeripheralManager(WeakReference(flutterPluginBinding.applicationContext))

        val scanForPeripheralsEventChannel =
            EventChannel(flutterPluginBinding.binaryMessenger, CENTRAL_MANAGER_SCAN_FOR_PERIPHERALS_NOTIFICATION_NAME)
        scanForPeripheralsEventChannel.setStreamHandler(ScanForPeripheralsHandler(centralManager))

        val centralStateEventChannel = EventChannel(flutterPluginBinding.binaryMessenger, CENTRAL_MANAGER_GET_STATE_NOTIFICATION_NAME)
        centralStateEventChannel.setStreamHandler(AdapterStateHandler(centralManager))

        val peripheralStateEventChannel = EventChannel(flutterPluginBinding.binaryMessenger, PERIPHERAL_MANAGER_GET_STATE_NOTIFICATION_NAME)
        peripheralStateEventChannel.setStreamHandler(AdapterStateHandler(peripheralManager))

        val periphChanOpenedEventChannel =
            EventChannel(flutterPluginBinding.binaryMessenger, PERIPHERAL_MANAGER_CHANNEL_OPENED_NOTIFICATION_NAME)
        periphChanOpenedEventChannel.setStreamHandler(PeripheralManagerChannelOpenedHandler(peripheralManager))
    }

    override fun onMethodCall(
        call: MethodCall,
        result: Result,
    ) {
        try {
            onMethodCallInternal(call, result)
        } catch (error: Throwable) {
            sendFlutterError(call.method, error, result)
        }
    }

    private fun <T> requireNotNullArgument(
        call: MethodCall,
        name: String,
    ): T = requireNotNull(call.argument(name)) { name }

    private fun onMethodCallInternal(
        call: MethodCall,
        result: Result,
    ) {
        when (call.method) {
            // Peripheral methods
            "peripheralManagerReset" -> {
                flutterMethodCallHandler(call.method, peripheralManager::reset, result)
            }
            "peripheralManagerAddReadOnlyService" -> {
                val uuid: String = requireNotNullArgument(call, UUID_PARAM_NAME)
                val svcTypeUUID = UUID.fromString(uuid)
                val svc = BluetoothGattService(svcTypeUUID, BluetoothGattService.SERVICE_TYPE_PRIMARY)
                val charDescs: Map<String, String> = requireNotNullArgument(call, CHARACTERISTICS_PARAM_NAME)
                charDescs.forEach {
                    val charTypeUUID = UUID.fromString(it.key)
                    val char =
                        BluetoothGattCharacteristic(
                            charTypeUUID,
                            BluetoothGattCharacteristic.PROPERTY_READ,
                            BluetoothGattCharacteristic.PERMISSION_READ,
                        )
                    svc.addCharacteristic(char)
                }
                flutterMethodCallHandler(call.method, {
                    peripheralManager.addService(svcTypeUUID, charDescs)
                }, result)
            }
            "peripheralManagerStartAdvertising" -> {
                val name: String = requireNotNullArgument(call, NAME_PARAM_NAME)
                flutterMethodCallHandler(call.method, {
                    peripheralManager.startAdvertising(name)
                }, result)
            }
            "peripheralManagerPublishChannel" -> {
                flutterMethodCallHandler(call.method, peripheralManager::publishChannel, result)
            }
            "peripheralManagerUnpublishChannel" -> {
                val psm: Int = requireNotNullArgument(call, PSM_PARAM_NAME)
                flutterMethodCallHandler(call.method, {
                    peripheralManager.unpublishChannel(psm)
                }, result)
            }
            "peripheralManagerWriteToChannel" -> {
                val psm: Int = requireNotNullArgument(call, PSM_PARAM_NAME)
                val cid: Int = requireNotNullArgument(call, CID_PARAM_NAME)
                val data: ByteArray = requireNotNullArgument(call, DATA_PARAM_NAME)
                flutterMethodCallHandler(call.method, {
                    val chan =
                        peripheralManager.getChannel(psm, cid)
                            ?: throw Exception("channel $psm:$cid not found")
                    chan.write(data)
                }, result)
            }
            "peripheralManagerReadFromChannel" -> {
                val psm: Int = requireNotNullArgument(call, PSM_PARAM_NAME)
                val cid: Int = requireNotNullArgument(call, CID_PARAM_NAME)
                val maxRead: Int = requireNotNullArgument(call, MAX_READ_PARAM_NAME)
                flutterMethodCallHandler(call.method, {
                    val chan =
                        peripheralManager.getChannel(psm, cid)
                            ?: throw Exception("channel $psm:$cid not found")
                    chan.read(maxRead)
                }, result)
            }
            "peripheralManagerCloseChannel" -> {
                val psm: Int = requireNotNullArgument(call, PSM_PARAM_NAME)
                val cid: Int = requireNotNullArgument(call, CID_PARAM_NAME)
                flutterMethodCallHandler(call.method, {
                    val chan =
                        peripheralManager.getChannel(psm, cid)
                            ?: throw Exception("channel $psm:$cid not found")
                    chan.close()
                }, result)
            }

            // Central methods
            "centralManagerReset" -> {
                flutterMethodCallHandler(call.method, centralManager::reset, result)
            }
            "centralManagerStopScanningForPeripherals" -> {
                flutterMethodCallHandler(call.method, centralManager::stopScanningForPeripherals, result)
            }
            "centralManagerConnectToDevice" -> {
                val macAddress: String = requireNotNullArgument(call, DEVICE_ID_PARAM_NAME)
                flutterMethodCallHandler(call.method, {
                    centralManager.connectToDevice(macAddress)
                }, result)
            }
            "centralManagerDisconnectFromDevice" -> {
                val macAddress: String = requireNotNullArgument(call, DEVICE_ID_PARAM_NAME)
                flutterMethodCallHandler(call.method, {
                    centralManager.disconnectFromDevice(macAddress)
                }, result)
            }
            "centralManagerReadCharacteristic" -> {
                val macAddress: String = requireNotNullArgument(call, DEVICE_ID_PARAM_NAME)
                val serviceId: String = requireNotNullArgument(call, SERVICE_ID_PARAM_NAME)
                val charId: String = requireNotNullArgument(call, CHARACTERISTIC_ID_PARAM_NAME)
                flutterMethodCallHandler(call.method, {
                    val periph =
                        centralManager.getPeripheral(macAddress)
                            ?: throw Exception("peripheral $macAddress not found")
                    periph.readCharacteristic(serviceId, charId)
                }, result)
            }
            "centralManagerConnectToChannel" -> {
                val macAddress: String = requireNotNullArgument(call, DEVICE_ID_PARAM_NAME)
                val psm: Int = requireNotNullArgument(call, PSM_PARAM_NAME)
                flutterMethodCallHandler(call.method, {
                    val periph =
                        centralManager.getPeripheral(macAddress)
                            ?: throw Exception("peripheral $macAddress not found")
                    periph.connectToL2CAPChannel(psm)
                }, result)
            }
            "centralManagerWriteToChannel" -> {
                val macAddress: String = requireNotNullArgument(call, DEVICE_ID_PARAM_NAME)
                val psm: Int = requireNotNullArgument(call, PSM_PARAM_NAME)
                val cid: Int = requireNotNullArgument(call, CID_PARAM_NAME)
                val data: ByteArray = requireNotNullArgument(call, DATA_PARAM_NAME)
                flutterMethodCallHandler(call.method, {
                    val periph =
                        centralManager.getPeripheral(macAddress)
                            ?: throw Exception("peripheral $macAddress not found")
                    val chan = periph.getChannel(psm, cid) ?: throw Exception("channel $psm:$cid not found")
                    chan.write(data)
                }, result)
            }
            "centralManagerReadFromChannel" -> {
                val macAddress: String = requireNotNullArgument(call, DEVICE_ID_PARAM_NAME)
                val psm: Int = requireNotNullArgument(call, PSM_PARAM_NAME)
                val cid: Int = requireNotNullArgument(call, CID_PARAM_NAME)
                val maxRead: Int = requireNotNullArgument(call, MAX_READ_PARAM_NAME)
                flutterMethodCallHandler(call.method, {
                    val periph =
                        centralManager.getPeripheral(macAddress)
                            ?: throw Exception("peripheral $macAddress not found")
                    val chan = periph.getChannel(psm, cid) ?: throw Exception("channel $psm:$cid not found")
                    chan.read(maxRead)
                }, result)
            }
            "centralManagerCloseChannel" -> {
                val macAddress: String = requireNotNullArgument(call, DEVICE_ID_PARAM_NAME)
                val psm: Int = requireNotNullArgument(call, PSM_PARAM_NAME)
                val cid: Int = requireNotNullArgument(call, CID_PARAM_NAME)
                flutterMethodCallHandler(call.method, {
                    val periph =
                        centralManager.getPeripheral(macAddress)
                            ?: throw Exception("peripheral $macAddress not found")
                    val chan = periph.getChannel(psm, cid) ?: throw Exception("channel $psm:$cid not found")
                    chan.close()
                }, result)
            }
            else -> {
                result.notImplemented()
            }
        }
    }

    private fun sendFlutterError(
        methodName: String,
        error: Throwable,
        result: Result,
    ) {
        Log.d(TAG, "error during $methodName call ${error.stackTraceToString()}")
        result.error(makeCallError(methodName), error.localizedMessage, null)
    }

    private fun <T> flutterMethodCallHandler(
        methodName: String,
        call: suspend () -> T,
        result: Result,
    ) {
        CoroutineScope(Dispatchers.Main).launch(
            CoroutineExceptionHandler { _, error ->
                sendFlutterError(methodName, error, result)
            },
        ) {
            val ret = call.invoke()
            if (ret is Unit) {
                result.success(null)
                return@launch
            }
            result.success(ret)
        }
    }

    override fun onDetachedFromEngine(binding: FlutterPlugin.FlutterPluginBinding) {
        channel.setMethodCallHandler(null)
    }
}

private fun makeCallError(methodName: String): String = "${methodName}Error"

fun stateFromAdapter(state: Int): Int =
    when (state) {
        BluetoothAdapter.STATE_TURNING_ON -> 1
        BluetoothAdapter.STATE_TURNING_OFF -> 4
        BluetoothAdapter.STATE_OFF -> 4
        BluetoothAdapter.STATE_ON -> 5
        else -> {
            0
        }
    }

class ScanForPeripheralsHandler(
    private val centralManager: CentralManager,
) : EventChannel.StreamHandler {
    private val sinks: MutableList<EventSink> = mutableListOf()
    private val sinksMutex = Mutex()
    private val scopes: MutableList<CoroutineScope> = mutableListOf()

    override fun onListen(
        arguments: Any?,
        events: EventSink?,
    ) {
        if (events == null) {
            return
        }
        val serviceIds: List<String> = requireNotNull(argument(arguments, "service_ids")) { "service_ids" }

        CoroutineScope(Dispatchers.Main).launch {
            sinksMutex.withLock {
                sinks.add(events)
                scopes.add(this)
            }
            centralManager.scanForPeripherals(serviceIds)
            centralManager.scanForPeripheralFlow.takeWhile { this.isActive }.collect { periphInfo: kotlin.Result<Map<String, Any?>> ->
                sinksMutex.withLock {
                    sinks.forEach {
                        if (periphInfo.isSuccess) {
                            it.success(periphInfo.getOrThrow())
                        } else {
                            it.error(
                                makeCallError(CENTRAL_MANAGER_SCAN_FOR_PERIPHERALS_NOTIFICATION_NAME),
                                periphInfo.exceptionOrNull()?.toString(),
                                null,
                            )
                        }
                    }
                }
            }
        }
    }

    override fun onCancel(arguments: Any?) {
        CoroutineScope(Dispatchers.Main).launch {
            sinksMutex.withLock {
                sinks.clear()
                scopes.forEach {
                    it.cancel()
                }
            }
        }
    }
}

class AdapterStateHandler(
    private val manager: BluetoothManager,
) : EventChannel.StreamHandler {
    private val sinks: MutableList<EventSink> = mutableListOf()
    private val sinksMutex = Mutex()
    private val scopes: MutableList<CoroutineScope> = mutableListOf()

    override fun onListen(
        arguments: Any?,
        events: EventSink?,
    ) {
        if (events == null) {
            return
        }

        CoroutineScope(Dispatchers.Main).launch {
            scopes.add(this)
            manager.stateFlow.takeWhile { this.isActive }.collect { state ->
                sinksMutex.withLock {
                    sinks.forEach {
                        it.success(stateFromAdapter(state))
                    }
                }
            }
        }

        // always emit the current state
        CoroutineScope(Dispatchers.Main).launch {
            sinksMutex.withLock {
                sinks.add(events)
            }

            sinksMutex.withLock {
                sinks.forEach {
                    it.success(stateFromAdapter(manager.state))
                }
            }
        }
    }

    override fun onCancel(arguments: Any?) {
        CoroutineScope(Dispatchers.Main).launch {
            sinksMutex.withLock {
                sinks.clear()
                scopes.forEach {
                    it.cancel()
                }
            }
        }
    }
}

class PeripheralManagerChannelOpenedHandler(
    private val peripheralManager: PeripheralManager,
) : EventChannel.StreamHandler {
    private val scopes: MutableMap<Int, CoroutineScope> = mutableMapOf()
    private val sinks: MutableMap<Int, EventSink> = mutableMapOf()
    private val sinksMutex = Mutex()

    override fun onListen(
        arguments: Any?,
        events: EventSink?,
    ) {
        if (events == null) {
            return
        }

        val psm: Int = requireNotNull(argument(arguments, PSM_PARAM_NAME)) { PSM_PARAM_NAME }
        CoroutineScope(Dispatchers.Main).launch {
            sinksMutex.withLock {
                sinks[psm] = events
                if (scopes.containsKey(psm)) {
                    scopes[psm]?.cancel()
                    scopes.remove(psm)
                }
                scopes[psm] = this
            }

            val chansForPSM =
                peripheralManager.getChannelManager(psm)
                    ?: throw Exception("channel manager for $psm not found")
            chansForPSM.channelOpenedFlow.takeWhile { this.isActive }.collect { cid: Int ->
                sinksMutex.withLock {
                    sinks[psm]?.success(cid)
                }
            }
        }
    }

    override fun onCancel(arguments: Any?) {
        if (arguments == null) {
            sinks.clear()
            scopes.forEach {
                it.value.cancel()
            }
            return
        }
        val psm: Int = requireNotNull(argument(arguments, PSM_PARAM_NAME)) { PSM_PARAM_NAME }
        CoroutineScope(Dispatchers.Main).launch {
            sinksMutex.withLock {
                sinks.remove(psm)
                scopes[psm]?.cancel()
            }
        }
    }
}

@Suppress("UNCHECKED_CAST")
fun <T> argument(
    from: Any?,
    key: String,
): T? =
    when (from) {
        null -> {
            null
        }
        is Map<*, *> -> {
            from[key] as T?
        }

        is JSONObject -> {
            from.opt(key) as T
        }

        else -> {
            throw ClassCastException()
        }
    }
