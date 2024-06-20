// swiftlint:disable file_length
import Flutter
import CoreBluetooth

// swiftlint:disable identifier_name
let kCentralManagerScanForPeripheralsNotificationName = "centralManagerScanForPeripherals"
let kCentralManagerGetStateNotificationName = "centralManagerGetState"
let kPeripheralManagerGetStateNotificationName = "peripheralManagerGetState"
let kPeripheralManagerChannelOpenedNotificationName = "peripheralManagerChannelOpened"
let kUUIDParamName = "uuid"
let kCharacteristicsParamName = "characteristics"
let kPSMParamName = "psm"
let kCIDParamName = "cid"
let kNameParamName = "name"
let kDataParamName = "data"
let kMaxReadParamName = "max_read"
let kDeviceIdParamName = "device_id"
let kServiceIdParamName = "service_id"
let kCharacteristicIdParamName = "characteristic_id"
// swiftlint:enable identifier_name

// BlePlugin is the entry point for Flutter into the iOS platform.
// It provides access to the CentralManager and PeripheralManager.
// swiftlint:disable:next type_body_length
public class BlePlugin: NSObject, FlutterPlugin {

    public static func register(with registrar: FlutterPluginRegistrar) {
        let channel = FlutterMethodChannel(name: "ble", binaryMessenger: registrar.messenger())
        let instance = BlePlugin()
        registrar.addMethodCallDelegate(instance, channel: channel)

        let scanForPeripheralsEventChannel = FlutterEventChannel(
            name: kCentralManagerScanForPeripheralsNotificationName, binaryMessenger: registrar.messenger())
        scanForPeripheralsEventChannel.setStreamHandler(ScanForPeripheralsHandler())

        let centralStateEventChannel = FlutterEventChannel(
            name: kCentralManagerGetStateNotificationName, binaryMessenger: registrar.messenger())
        centralStateEventChannel.setStreamHandler(
            AdapterStateHandler(
                notifName: kCentralManagerGetStateNotificationName,
                stateGetter: CentralManager.singleton.getState))

        let periphStateEventChannel = FlutterEventChannel(
            name: kPeripheralManagerGetStateNotificationName, binaryMessenger: registrar.messenger())
        periphStateEventChannel.setStreamHandler(
            AdapterStateHandler(
                notifName: kPeripheralManagerGetStateNotificationName,
                stateGetter: PeripheralManager.singleton.getState))

        let periphChanOpenedEventChannel = FlutterEventChannel(
            name: kPeripheralManagerChannelOpenedNotificationName, binaryMessenger: registrar.messenger())
        periphChanOpenedEventChannel.setStreamHandler(PeripheralManagerChannelOpenedHandler())
    }

    override private init() {
        super.init()
    }

    // swiftlint:disable:next cyclomatic_complexity function_body_length
    private func handleInternal(_ call: FlutterMethodCall, result: @escaping FlutterResult) throws {
        switch call.method {
        /// peripheral methods
        case "peripheralManagerReset":
            flutterMethodCallHandler(methodName: call.method, call: PeripheralManager.singleton.reset, result: result)
            return
        case "peripheralManagerAddReadOnlyService":
            if let arguments = call.arguments as? [String: Any],
               let uuid = arguments[kUUIDParamName] as? String,
               let charDescs = arguments[kCharacteristicsParamName] as? [String: String] {
                var chars: [CBMutableCharacteristic] = []
                guard let svcTypeUUID = UUID(uuidString: uuid) else {
                    throwInvalidArguments(call, result, "invalid service type UUID")
                    return
                }
                for (charUUID, value) in charDescs {
                    guard let charTypeUUID = UUID(uuidString: charUUID) else {
                        throwInvalidArguments(call, result, "invalid characteristic type UUID")
                        return
                    }
                    chars.append(CBMutableCharacteristic(
                                    type: CBUUID(nsuuid: charTypeUUID),
                                    properties: [.read],
                                    value: value.data(using: .utf8),
                                    permissions: [.readable]))
                }
                let svc = CBMutableService(type: CBUUID(nsuuid: svcTypeUUID), primary: true)
                svc.characteristics = chars
                try PeripheralManager.singleton.addService(svc)
            } else {
                throwInvalidArguments(call, result)
            }
            result(nil)
            return
        case "peripheralManagerStartAdvertising":
            if let arguments = call.arguments as? [String: Any],
               let name = arguments[kNameParamName] as? String {
                try PeripheralManager.singleton.startAdvertising(withName: name)
                result(nil)
            } else {
                throwInvalidArguments(call, result)
            }
            return
        case "peripheralManagerPublishChannel":
            flutterMethodCallHandler(
                methodName: call.method,
                call: PeripheralManager.singleton.publishChannel, result: result)
            return
        case "peripheralManagerUnpublishChannel":
            if let arguments = call.arguments as? [String: Any],
               let psm = arguments[kPSMParamName] as? Int {
                flutterMethodCallHandler(methodName: call.method, call: {
                    return try await PeripheralManager.singleton.unpublishChannel(psm: psm)
                }, result: result)
            } else {
                throwInvalidArguments(call, result)
            }
            return
        case "peripheralManagerWriteToChannel":
            if let arguments = call.arguments as? [String: Any],
               let psm = arguments[kPSMParamName] as? Int,
               let cid = arguments[kCIDParamName] as? Int,
               let data = arguments[kDataParamName] as? FlutterStandardTypedData {
                guard let chan = try PeripheralManager.singleton.getChannel(psm: psm, cid: cid) else {
                    throwInvalidArguments(call, result, "channel not found")
                    return
                }
                flutterMethodCallHandler(
                    methodName: call.method,
                    call: { [weak chan] in try await chan?.write(data: data.data) }, result: result)
            } else {
                throwInvalidArguments(call, result)
            }
            return
        case "peripheralManagerReadFromChannel":
            if let arguments = call.arguments as? [String: Any],
               let psm = arguments[kPSMParamName] as? Int,
               let cid = arguments[kCIDParamName] as? Int,
               let maxRead = arguments[kMaxReadParamName] as? Int {
                guard let chan = try PeripheralManager.singleton.getChannel(psm: psm, cid: cid) else {
                    throwInvalidArguments(call, result, "channel not found")
                    return
                }
                flutterMethodCallHandler(
                    methodName: call.method,
                    call: { [weak chan] in return try await chan?.read(maxRead: maxRead) }, result: result)
            } else {
                throwInvalidArguments(call, result)
            }
            return
        case "peripheralManagerCloseChannel":
            if let arguments = call.arguments as? [String: Any],
               let psm = arguments[kPSMParamName] as? Int,
               let cid = arguments[kCIDParamName] as? Int {
                guard let chan = try PeripheralManager.singleton.getChannel(psm: psm, cid: cid) else {
                    throwInvalidArguments(call, result, "channel not found")
                    return
                }
                flutterMethodCallHandler(methodName: call.method, call: chan.close, result: result)
            } else {
                throwInvalidArguments(call, result)
            }
            return

        /// central methods
        case "centralManagerReset":
            flutterMethodCallHandler(methodName: call.method, call: CentralManager.singleton.reset, result: result)
            return
        case "centralManagerStopScanningForPeripherals":
            try CentralManager.singleton.stopScanningForPeripherals()
            result(true)
            return
        case "centralManagerConnectToDevice":
            if let arguments = call.arguments as? [String: Any],
               let deviceId = arguments[kDeviceIdParamName] as? String {
                flutterMethodCallHandler(
                    methodName: call.method,
                    call: { return try await CentralManager.singleton.connectToDevice(deviceId: deviceId) },
                    result: result)
            } else {
                throwInvalidArguments(call, result)
            }
            return
        case "centralManagerReadCharacteristic":
            if let arguments = call.arguments as? [String: Any],
               let deviceId = arguments[kDeviceIdParamName] as? String,
               let svcId = arguments[kServiceIdParamName] as? String,
               let charId = arguments[kCharacteristicIdParamName] as? String {
                guard let periph = try CentralManager.singleton.getPeripheral(deviceId) else {
                    throwInvalidArguments(call, result, "peripheral not found")
                    return
                }
                let service = periph.actualPeripheral.services?.first(where: { elem in
                    return elem.uuid.uuidString == svcId
                })
                let characteristic = service?.characteristics?.first(where: { char in
                    return char.uuid.uuidString == charId
                })

                if let characteristic {
                    flutterMethodCallHandler(
                        methodName: call.method,
                        call: { [weak periph] in return try await periph?
                            .readCharacteristic(characteristic) }, result: result)
                    return
                }
                result(createFltuterError(call.method, withMessage: "failed to find given characteristic to read"))
            } else {
                throwInvalidArguments(call, result)
            }
            return
        case "centralManagerDisconnectFromDevice":
            if let arguments = call.arguments as? [String: Any],
               let deviceId = arguments[kDeviceIdParamName] as? String {
                flutterMethodCallHandler(
                    methodName: call.method,
                    call: { return try await CentralManager.singleton.disconnectFromDevice(deviceId: deviceId) },
                    result: result)
            } else {
                throwInvalidArguments(call, result)
            }
            return
        case "centralManagerConnectToChannel":
            if let arguments = call.arguments as? [String: Any],
               let deviceId = arguments[kDeviceIdParamName] as? String,
               let psm = arguments[kPSMParamName] as? UInt16 {
                guard let periph = try CentralManager.singleton.getPeripheral(deviceId) else {
                    throwInvalidArguments(call, result, "peripheral not found")
                    return
                }
                flutterMethodCallHandler(
                    methodName: call.method,
                    call: { return try await periph.connectToL2CAPChannel(psm: psm) }, result: result)
            } else {
                throwInvalidArguments(call, result)
            }
            return
        case "centralManagerWriteToChannel":
            if let arguments = call.arguments as? [String: Any],
               let deviceId = arguments[kDeviceIdParamName] as? String,
               let psm = arguments[kPSMParamName] as? Int,
               let cid = arguments[kCIDParamName] as? Int,
               let data = arguments[kDataParamName] as? FlutterStandardTypedData {
                guard let periph = try CentralManager.singleton.getPeripheral(deviceId) else {
                    throwInvalidArguments(call, result, "peripheral not found")
                    return
                }
                guard let chan = periph.channels[psm]?.getChannel(cid: cid) else {
                    throwInvalidArguments(call, result, "channel not found")
                    return
                }
                flutterMethodCallHandler(
                    methodName: call.method,
                    call: { [weak chan] in return try await chan?.write(data: data.data) }, result: result)
            } else {
                throwInvalidArguments(call, result)
            }
            return
        case "centralManagerReadFromChannel":
            if let arguments = call.arguments as? [String: Any],
               let deviceId = arguments[kDeviceIdParamName] as? String,
               let psm = arguments[kPSMParamName] as? Int,
               let cid = arguments[kCIDParamName] as? Int,
               let maxRead = arguments[kMaxReadParamName] as? Int {
                guard let periph = try CentralManager.singleton.getPeripheral(deviceId) else {
                    throwInvalidArguments(call, result, "peripheral not found")
                    return
                }
                guard let chan = periph.channels[psm]?.getChannel(cid: cid) else {
                    throwInvalidArguments(call, result, "channel not found")
                    return
                }
                flutterMethodCallHandler(
                    methodName: call.method,
                    call: { [weak chan] in return try await chan?.read(maxRead: maxRead) }, result: result)
            } else {
                throwInvalidArguments(call, result)
            }
            return
        case "centralManagerCloseChannel":
            if let arguments = call.arguments as? [String: Any],
               let deviceId = arguments[kDeviceIdParamName] as? String,
               let psm = arguments[kPSMParamName] as? Int,
               let cid = arguments[kCIDParamName] as? Int {
                guard let periph = try CentralManager.singleton.getPeripheral(deviceId) else {
                    throwInvalidArguments(call, result, "peripheral not found")
                    return
                }
                guard let chan = periph.channels[psm]?.getChannel(cid: cid) else {
                    throwInvalidArguments(call, result, "channel not found")
                    return
                }
                flutterMethodCallHandler(methodName: call.method, call: chan.close, result: result)
            } else {
                throwInvalidArguments(call, result)
            }
            return
        default:
            break
        }
        result(FlutterMethodNotImplemented)
    }

    public func handle(_ call: FlutterMethodCall, result: @escaping FlutterResult) {
        do {
            try handleInternal(call, result: result)
        } catch {
            result(createFltuterError(call.method, withError: error))
        }
    }

    private func flutterMethodCallHandler<T>(
        methodName: String, call: @escaping () async throws -> T?, result: @escaping FlutterResult) {
        Task.init {
            do {
                let ret = try await call()
                if ret == nil || T.self == Void.self {
                    result(nil)
                    return
                }
                result(ret)
            } catch {
                result(createFltuterError(methodName, withError: error))
            }
        }
    }

    private func throwInvalidArguments(_ call: FlutterMethodCall, _ result: FlutterResult) {
        result(createFltuterError(call.method, withMessage: "invalid arguments"))
    }

    private func throwInvalidArguments(_ call: FlutterMethodCall, _ result: FlutterResult, _ message: String) {
        result(createFltuterError(call.method, withMessage: "invalid arguments: \(message)"))
    }
}

private func createFltuterError(_ methodName: String, withMessage message: String) -> FlutterError {
    return FlutterError(code: makeCallError(methodName), message: message, details: nil)
}

private func createFltuterError(_ methodName: String, withError error: Error) -> FlutterError {
    return FlutterError(code: makeCallError(methodName), message: error.localizedDescription, details: nil)
}

private func makeCallError(_ methodName: String) -> String {
    return "\(methodName)Error"
}

class AdapterStateHandler: NSObject, FlutterStreamHandler {
    private var eventSink: FlutterEventSink?
    private var eventSinkLock: NSLock = NSLock()
    private let notifName: String
    private let stateGetter: () -> CBManagerState

    public init(notifName: String, stateGetter: @escaping () -> CBManagerState) {
        self.notifName = notifName
        self.stateGetter = stateGetter
    }

    public func onListen(
        withArguments arguments: Any?, eventSink events: @escaping FlutterEventSink) -> FlutterError? {
        eventSinkLock.withLock {
            self.eventSink = events
        }
        NotificationCenter.default.addObserver(
            forName: Notification.Name(self.notifName),
            object: nil,
            queue: OperationQueue.main) { [weak self] notif in
            self?.emitEvent(notification: notif)
        }
        // always emit the current state
        let userInfo = makeAdapterState(state: self.stateGetter())
        NotificationCenter.default.post(
            name: Notification.Name(self.notifName), object: nil, userInfo: userInfo)
        return nil
    }

    public func onCancel(withArguments arguments: Any?) -> FlutterError? {
        eventSinkLock.withLock {
            self.eventSink = nil
        }
        return nil
    }

    @objc func emitEvent(notification: Notification) {
        eventSinkLock.withLock {
            guard let eventSink = self.eventSink,
                  let userInfo = notification.userInfo,
                  let updatedState = userInfo["state"] as? Int32 else {
                return
            }
            eventSink(updatedState)
        }
    }
}

class ScanForPeripheralsHandler: NSObject, FlutterStreamHandler {
    private var eventSink: FlutterEventSink?
    private var eventSinkLock: NSLock = NSLock()

    public func onListen(
        withArguments arguments: Any?, eventSink events: @escaping FlutterEventSink) -> FlutterError? {
        var serviceIds: [CBUUID]?
        if let arguments = arguments as? [String: Any],
           let serviceIdsActual = arguments["service_ids"] as? [String] {
            serviceIds = serviceIdsActual.map { svcId in
                CBUUID(string: svcId)
            }
        }

        do {
            try CentralManager.singleton.scanForPeripherals(withServices: serviceIds)
        } catch {
            return createFltuterError(kCentralManagerScanForPeripheralsNotificationName, withError: error)
        }

        eventSinkLock.withLock {
            self.eventSink = events
        }
        NotificationCenter.default.addObserver(
            forName: Notification.Name(kCentralManagerScanForPeripheralsNotificationName),
            object: nil,
            queue: OperationQueue.main) { [weak self] notif in
            self?.emitPeripheralInfo(notif)
        }
        return nil
    }

    public func onCancel(withArguments arguments: Any?) -> FlutterError? {
        eventSinkLock.withLock {
            self.eventSink = nil
        }
        return nil
    }

    @objc func emitPeripheralInfo(_ notif: Notification) {
        eventSinkLock.withLock {
            guard let eventSink = self.eventSink else {
                return
            }
            eventSink(notif.userInfo)
        }
    }
}

class PeripheralManagerChannelOpenedHandler: NSObject, FlutterStreamHandler {
    private var observers: [Int: NSObjectProtocol] = [:]
    private var eventSink: [Int: FlutterEventSink] = [:]
    private var eventSinkLock: NSLock = NSLock()

    public func onListen(
        withArguments arguments: Any?, eventSink events: @escaping FlutterEventSink) -> FlutterError? {
        if let arguments = arguments as? [String: Any],
           let psm = arguments[kPSMParamName] as? Int {
            do {
                guard let chansForPSM = try PeripheralManager.singleton.getChannelManager(psm: psm) else {
                    return createFltuterError(
                        kPeripheralManagerChannelOpenedNotificationName,
                        withError: RuntimeError("channel manager not found for \(psm)"))
                }

                eventSinkLock.withLock {
                    self.eventSink[psm] = events
                    if let obs = self.observers[psm] {
                        NotificationCenter.default.removeObserver(obs)
                    }
                }
                let token = NotificationCenter.default.addObserver(
                    forName: Notification.Name(kPeripheralManagerChannelOpenedNotificationName),
                    object: chansForPSM,
                    queue: OperationQueue.main) { [weak self] notif in
                    self?.eventSinkLock.withLock {
                        guard let eventSink = self?.eventSink[psm],
                              let userInfo = notif.userInfo,
                              let newCID = userInfo["cid"] as? Int32 else {
                            return
                        }
                        eventSink(newCID)
                    }
                }
                eventSinkLock.withLock {
                    self.observers[psm] = token
                }
                return nil
            } catch {
                return createFltuterError(kPeripheralManagerChannelOpenedNotificationName, withError: error)
            }
        } else {
            return createFltuterError(kPeripheralManagerChannelOpenedNotificationName, withMessage: "invalid arguments")
        }
    }

    public func onCancel(withArguments arguments: Any?) -> FlutterError? {
        if let arguments = arguments as? [String: Any],
           let psm = arguments[kPSMParamName] as? Int {
            eventSinkLock.withLock {
                self.eventSink[psm] = nil
                if let obs = self.observers[psm] {
                    NotificationCenter.default.removeObserver(obs)
                }
            }
            return nil
        }
        eventSinkLock.withLock {
            self.eventSink.removeAll()
            self.observers.forEach { obs in
                NotificationCenter.default.removeObserver(obs)
            }
        }
        return nil
    }
}
