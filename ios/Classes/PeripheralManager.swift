import CoreBluetooth
import Foundation

/// PeripheralManager is our iOS based BLE Peripheral manager.
/// It is a singleton so that we don't double up on any bluetooth operations that would cause an
/// incorrect or unexpected program state.
public class PeripheralManager: NSObject {

    static let singleton = PeripheralManager()

    private lazy var manager: CBPeripheralManager = {
        return CBPeripheralManager(delegate: self, queue: managerQueue)
    }()

    private var managerQueue = DispatchQueue.global(qos: .utility)
    var channels: [Int: L2CAPChannelManager] = [:] // psm:manager
    var channelsLock: NSLock = NSLock()

    private var publishChannelContinuations: [CheckedContinuation<Int, Error>] = []
    private var publishChannelContinuationsLock: NSLock = NSLock()

    private var servicesToAdvertise: [CBMutableService] = []
    private var servicesToAdvertiseLock: NSLock = NSLock()

    private override init() {
        super.init()
    }

    public func reset() async {
        self.manager.removeAllServices()
        self.servicesToAdvertiseLock.withLock {
            self.servicesToAdvertise.removeAll()
        }
        if self.manager.state == CBManagerState.poweredOn {
            self.manager.stopAdvertising()
        }
        self.publishChannelContinuationsLock.withLock {
            self.publishChannelContinuations.forEach({ continuation in
                continuation.resume(throwing: RuntimeError("canceled"))
            })
        }

        var readCopy: [L2CAPChannelManager] = []
        channelsLock.withLock {
            readCopy = channels.values.map { $0 }
        }
        await readCopy.asyncForEach { chanMan in
            do {
                try await self.unpublishChannel(psm: chanMan.psm)
            } catch {
                debugPrint("error unpublishing psm \(chanMan.psm): \(error)")
            }
            chanMan.close()
        }
        channelsLock.withLock {
            channels.removeAll()
        }
    }

    // This should be called for all methods that would expect the power to be on. Not calling this
    // won't cause any bad state but we may not return the best errors as a result.
    private func mustBePoweredOn() throws {
        guard self.manager.state == CBManagerState.poweredOn else {
            throw RuntimeError("must be powered on first before calling any non-state methods")
        }
    }

    public func publishChannel() async throws -> Int {
        try mustBePoweredOn()
        return try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Int, Error>) in
            self.publishChannelContinuationsLock.withLock {
                self.publishChannelContinuations.append(continuation)
            }
            manager.publishL2CAPChannel(withEncryption: true)
        }
    }

    public func unpublishChannel(psm: Int) async throws {
        var chansForPSM: L2CAPChannelManager?
        if (channelsLock.withLock {
            chansForPSM = channels[psm]
            if chansForPSM == nil {
                return true
            }
            return false
        }) {
            return
        }
        if chansForPSM == nil {
            return
        }

        chansForPSM!.close()
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            if chansForPSM!.startUnpublish(withContinuation: continuation) {
                self.manager.unpublishL2CAPChannel(UInt16(psm))
            }
        }
        channelsLock.withLock {
            self.channels[psm] = nil
        }

    }

    public func addService(_ service: CBMutableService) throws {
        try mustBePoweredOn()
        servicesToAdvertiseLock.withLock {
            if let alreadyAddedIdx = self.servicesToAdvertise.firstIndex(where: { existingSvc in
                existingSvc.uuid == service.uuid
            }) {
                manager.remove(self.servicesToAdvertise[alreadyAddedIdx])
                self.servicesToAdvertise.remove(at: alreadyAddedIdx)
            }
            manager.add(service)
            self.servicesToAdvertise.append(service)
        }
    }

    public func startAdvertising(withName: String?) throws {
        try mustBePoweredOn()
        var advertData: [String: Any] =
            [CBAdvertisementDataServiceUUIDsKey: servicesToAdvertise.map { $0.uuid }]
        if withName != nil {
            advertData[CBAdvertisementDataLocalNameKey] = withName
        }
        servicesToAdvertiseLock.withLock {
            manager.startAdvertising(advertData)
        }
    }

    public func getChannelManager(psm: Int) throws -> L2CAPChannelManager? {
        try mustBePoweredOn()
        return channelsLock.withLock { self.channels[psm] }
    }

    public func getChannel(psm: Int, cid: Int) throws -> L2CAPChannel? {
        try mustBePoweredOn()
        return channelsLock.withLock { self.channels[psm]?.getChannel(cid: cid) }
    }

    public func getState() -> CBManagerState {
        return self.manager.state
    }
}

// MARK: - CBPeripheralManagerDelegate

extension PeripheralManager: CBPeripheralManagerDelegate {
    public func peripheralManager(
        _ peripheral: CBPeripheralManager,
        didOpen channel: CBL2CAPChannel?, error: (any Error)?) {
        if let error = error {
            debugPrint("\(#function) error opening \(error.localizedDescription)")
            return
        }

        guard let channel = channel else {
            debugPrint("\(#function) expected a non-nil channel")
            return
        }

        guard let chansForPSM = (channelsLock.withLock { channels[Int(channel.psm)] }) else {
            debugPrint("\(#function) channel opened but no channel manager found for PSM \(channel.psm)")
            return
        }

        do {
            let newChanCID = try chansForPSM.handleChannelDidOpen(didOpen: channel)
            let userInfo = ["cid": NSNumber(value: newChanCID)]
            NotificationCenter.default.post(
                name: Notification.Name(kPeripheralManagerChannelOpenedNotificationName),
                object: chansForPSM, userInfo: userInfo)
        } catch {
            debugPrint("\(#function) channel opened but encountered error: \(error)")
        }
    }

    public func peripheralManagerDidUpdateState(_ peripheral: CBPeripheralManager) {
        let userInfo = makeAdapterState(state: peripheral.state)
        NotificationCenter.default.post(
            name: Notification.Name(kPeripheralManagerGetStateNotificationName),
            object: nil, userInfo: userInfo)
    }

    public func peripheralManager(_ peripheral: CBPeripheralManager,
                                  didUnpublishL2CAPChannel PSM: CBL2CAPPSM,
                                  error: Error?) {
        guard let chansForPSM = ( channelsLock.withLock { channels[Int(PSM)] })else {
            debugPrint("\(#function) called but no channel manager found for \(PSM)")
            return
        }

        let unpublishedContinuation = chansForPSM.takeUnpublishedContinuation()
        if let error = error {
            unpublishedContinuation?.resume(throwing: error)
            return
        }
        unpublishedContinuation?.resume()
    }

    public func peripheralManager(_ peripheral: CBPeripheralManager,
                                  didPublishL2CAPChannel PSM: CBL2CAPPSM,
                                  error: Error?) {
        if (self.publishChannelContinuationsLock.withLock {
            if publishChannelContinuations.isEmpty {
                debugPrint("\(#function) published a channel but no one is waiting")
                return true
            }
            return false
        }) {
            return
        }

        // take first
        var continuation: CheckedContinuation<Int, Error>?
        self.publishChannelContinuationsLock.withLock {
            continuation = publishChannelContinuations.removeFirst()
        }

        if let error = error {
            continuation?.resume(throwing: error)
            return
        }
        channelsLock.withLock {
            channels[Int(PSM)] = L2CAPChannelManager(psm: Int(PSM))
        }
        continuation?.resume(returning: Int(PSM))
    }
}
