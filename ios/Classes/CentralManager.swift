import CoreBluetooth
import Foundation

/// CentralManager is our iOS based BLE Central manager.
/// It is a singleton so that we don't double up on any bluetooth operations that would cause an
/// incorrect or unexpected program state.
public class CentralManager: NSObject {
    static let singleton = CentralManager()

    private var actualManager: CBCentralManager?
    private var manager: CBCentralManager {
        // This force unwrap is okay
        return actualManager!
    }

    private var managerQueue = DispatchQueue.global(qos: .utility)
    private var peripherals: [String: Peripheral] = [:]
    private var peripheralsLock: NSLock = NSLock()

    private override init() {
        super.init()
        actualManager = CBCentralManager(delegate: self, queue: managerQueue)
    }

    public func reset() async {
        if self.manager.state == CBManagerState.poweredOn {
            do {
                try self.stopScanningForPeripherals()
            } catch {
                debugPrint("error stopping scan for peripherals \(error)")
            }
        }

        var readCopy: [Peripheral] = []
        peripheralsLock.withLock {
            readCopy = peripherals.values.map { $0 }
        }
        await readCopy.asyncForEach { periph in
            await periph.close(manager: self)
        }
        peripheralsLock.withLock {
            peripherals.removeAll()
        }
    }

    // This should be called for all methods that would expect the power to be on. Not calling this
    // won't cause any bad state but we may not return the best errors as a result.
    private func mustBePoweredOn() throws {
        guard self.manager.state == CBManagerState.poweredOn else {
            throw RuntimeError("must be powered on first before calling any non-state methods")
        }
    }

    public func connectToDevice(deviceId: String) async throws -> [[String: Any]] {
        try mustBePoweredOn()
        guard let uuid = UUID(uuidString: deviceId),
              let peripheral = self.manager.retrievePeripherals(withIdentifiers: [uuid]).first else {
            throw RuntimeError("device with id \(deviceId) not found")
        }

        guard let periph = (peripheralsLock.withLock { self.peripherals.first(where: { elem in
            elem.key == deviceId
        }) }) else {
            var periph: Peripheral?
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                periph = Peripheral(peripheral: peripheral)
                peripheralsLock.withLock {
                    self.peripherals[deviceId] = periph
                }
                periph!.connect(manager: self, connectedContinuation: continuation)
            }
            // This force unwrap is okay
            return periph!.discoveredServices
        }

        return periph.value.discoveredServices
    }

    public func disconnectFromDevice(deviceId: String) async throws {
        try mustBePoweredOn()
        guard let periph = (peripheralsLock.withLock { self.peripherals[deviceId] }) else {
            return
        }
        await periph.close(manager: self)
    }

    public func connectPeripheral(_ peripheral: CBPeripheral) {
        self.manager.connect(peripheral)
    }

    public func cancelPeripheralConnection(_ peripheral: CBPeripheral) {
        self.manager.cancelPeripheralConnection(peripheral)
    }

    public func scanForPeripherals(withServices serviceUUIDs: [CBUUID]?) throws {
        try mustBePoweredOn()
        self.manager.scanForPeripherals(withServices: serviceUUIDs)
    }

    public func stopScanningForPeripherals() throws {
        try mustBePoweredOn()
        guard self.manager.state == CBManagerState.poweredOn else {
            return
        }
        self.manager.stopScan()
    }

    public func getPeripheral(_ deviceId: String) throws -> Peripheral? {
        try mustBePoweredOn()
        return peripheralsLock.withLock { self.peripherals[deviceId] }
    }

    public func getState() -> CBManagerState {
        return self.manager.state
    }
}

extension CentralManager: CBCentralManagerDelegate {

    public func centralManagerDidUpdateState(_ central: CBCentralManager) {
        let userInfo = makeAdapterState(state: central.state)
        NotificationCenter.default.post(
            name: Notification.Name(kCentralManagerGetStateNotificationName), object: nil, userInfo: userInfo)
    }

    public func centralManager(
        _ central: CBCentralManager,
        didDiscover peripheral: CBPeripheral,
        advertisementData: [String: Any], rssi RSSI: NSNumber) {

        let name = advertisementData[CoreBluetooth.CBAdvertisementDataLocalNameKey] as? String ?? peripheral.name ?? ""
        let serviceIDs = advertisementData[CoreBluetooth.CBAdvertisementDataServiceUUIDsKey] as? [CBUUID] ?? []
        let serviceIDStrings = serviceIDs.map({ CBUUID in
            CBUUID.uuidString
        })

        let dataToSend: [String: Any] = [
            "id": NSString(string: peripheral.identifier.uuidString),
            "name": NSString(string: name),
            "service_ids": serviceIDStrings
        ]
        NotificationCenter.default.post(
            name: Notification.Name(kCentralManagerScanForPeripheralsNotificationName),
            object: nil, userInfo: dataToSend)
    }

    public func centralManager(_ central: CBCentralManager, didConnect peripheral: CBPeripheral) {
        if (peripheralsLock.withLock { peripherals[peripheral.identifier.uuidString]}) != nil {
            peripheral.discoverServices(nil)
        } else {
            debugPrint("connected to device that is not in peripherals: \(peripheral.identifier.uuidString)")
        }
    }

    public func centralManager(_ central: CBCentralManager, didFailToConnect peripheral: CBPeripheral, error: Error?) {
        if let periph = (peripheralsLock.withLock { peripherals[peripheral.identifier.uuidString] }) {
            peripheralsLock.withLock { peripherals[peripheral.identifier.uuidString] = nil }
            periph.failedConnecting(withError: error ?? RuntimeError("failed to connect to peripheral"))
        }
    }

    public func centralManager(
        _ central: CBCentralManager, didDisconnectPeripheral peripheral: CBPeripheral, error: Error?) {
        if let periph = (peripheralsLock.withLock {peripherals[peripheral.identifier.uuidString]}) {
            peripheralsLock.withLock {
                peripherals[peripheral.identifier.uuidString] = nil
            }
            let disconnectedContinuation = periph.takeDisconnectedContinuation()
            let disconnectRequested = disconnectedContinuation != nil
            guard let error = error else {
                disconnectedContinuation?.resume()
                if !disconnectRequested {
                    // fire this off
                    Task {
                        await periph.closeOnDisconnect(manager: self, wasRequested: false)
                    }
                }
                return
            }
            disconnectedContinuation?.resume(throwing: error)
            if !disconnectRequested {
                // fire this off
                Task.init {
                    await periph.closeOnDisconnect(manager: self, wasRequested: false)
                }
            }
        } else {
            debugPrint("disconnected from device that is not in peripherals: \(peripheral.identifier.uuidString)")
        }
    }
}
