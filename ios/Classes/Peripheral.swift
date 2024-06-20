import CoreBluetooth
import Foundation

/// A Peripheral is managed by a PeripheralManager for use on the peripheral side of a BLE interaction.
public class Peripheral: NSObject {
    var actualPeripheral: CBPeripheral

    var contLocks: NSLock = NSLock()
    private var connectedContinuation: CheckedContinuation<Void, Error>?
    private var channelOpenedContinuation: CheckedContinuation<Void, Error>?
    private var disconnectedContinuation: CheckedContinuation<Void, Error>?
    private var channelConnectedContinuation: CheckedContinuation<Int, Error>?
    private var pendingCharReads: [CBUUID: [CheckedContinuation<Data, Error>]] = [:]

    var neededSvcDoneCount: Int = 0
    var discoveredSvcDoneCount: Int = 0
    public var discoveredServices: [[String: Any]] = []

    var channels: [Int: L2CAPChannelManager] = [:]
    var channelsLock: NSLock = NSLock()

    var isClosed: Bool = false
    var isClosedLock: NSLock = NSLock()

    init(peripheral: CBPeripheral) {
        self.actualPeripheral = peripheral
        super.init()
        peripheral.delegate = self
    }

    public func connect(manager: CentralManager, connectedContinuation: CheckedContinuation<Void, Error>) {
        if (contLocks.withLock {
            if self.connectedContinuation != nil {
                connectedContinuation.resume(throwing: RuntimeError("already connecting"))
                return true
            }
            self.connectedContinuation = connectedContinuation
            return false
        }) {
            return
        }
        manager.connectPeripheral(actualPeripheral)
    }

    public func failedConnecting(withError error: Error) {
        contLocks.withLock {
            connectedContinuation?.resume(throwing: error)
            connectedContinuation = nil
        }
    }

    public func takeDisconnectedContinuation() -> CheckedContinuation<Void, Error>? {
        return contLocks.withLock {
            let ref = disconnectedContinuation
            disconnectedContinuation = nil
            return ref
        }
    }

    public func readCharacteristic(_ characteristic: CBCharacteristic) async throws -> Data {
        contLocks.withLock {
            if self.pendingCharReads[characteristic.uuid] == nil {
                self.pendingCharReads[characteristic.uuid] = []
            }
        }
        return try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Data, Error>) in
            // This force unwrap is okay
            contLocks.withLock {
                self.pendingCharReads[characteristic.uuid]!.append(continuation)
            }
            self.actualPeripheral.readValue(for: characteristic)
        }
    }

    public func connectToL2CAPChannel(psm: UInt16) async throws -> Int {
        return try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Int, Error>) in
            channelsLock.withLock {
                var chansForPSM = channels[Int(psm)]
                if chansForPSM == nil {
                    chansForPSM = L2CAPChannelManager(psm: Int(psm))
                    channels[Int(psm)] = chansForPSM
                }
            }
            if (contLocks.withLock {
                guard channelConnectedContinuation == nil else {
                    // This restriction exists because if an error happens, the delegate will not receive
                    // the PSM on which the error happened. Therefore we need to keep track of what we're
                    // currently connecting to in order to emit any error to the correct, interested party.
                    continuation.resume(throwing: RuntimeError("can only connect one channel at a time"))
                    return true
                }
                channelConnectedContinuation = continuation
                return false
            }) {
                return
            }
            self.actualPeripheral.openL2CAPChannel(psm)
        }
    }

    public func close(manager: CentralManager) async {
        if (isClosedLock.withLock {
            if isClosed {
                return true
            }
            isClosed = true
            return false
        }) {
            return
        }

        await self.closeOnDisconnect(manager: manager, wasRequested: true)
        do {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                self.disconnectedContinuation = continuation
                manager.cancelPeripheralConnection(actualPeripheral)
            }
        } catch {
            debugPrint("error canceling peripheral connection: \(error)")
        }
    }

    public func closeOnDisconnect(manager: CentralManager, wasRequested: Bool) async {
        // cancel everything
        let error = wasRequested ? RuntimeError("peripheral closing") : RuntimeError("peripheral disconnected")

        contLocks.withLock {
            pendingCharReads.forEach { (_: CBUUID, value: [CheckedContinuation<Data, any Error>]) in
                value.forEach { cont in
                    cont.resume(throwing: error)
                }
            }
            pendingCharReads.removeAll()
            channelOpenedContinuation?.resume(throwing: error)
            channelOpenedContinuation = nil
            connectedContinuation?.resume(throwing: error)
            connectedContinuation = nil
        }

        var readCopy: [L2CAPChannelManager] = []
        channelsLock.withLock {
            readCopy = channels.values.map { $0 }
        }
        readCopy.forEach { chanMan in
            chanMan.close()
        }
        channelsLock.withLock {
            channels.removeAll()
        }
    }
}

extension Peripheral: CBPeripheralDelegate {
    public func peripheral(_ peripheral: CBPeripheral, didOpen channel: CBL2CAPChannel?, error: Error?) {

        if (contLocks.withLock {
            if let error = error {
                channelConnectedContinuation?.resume(throwing: error)
                return true
            }

            guard let channel = channel else {
                channelConnectedContinuation?.resume(throwing: RuntimeError("expected a non-nil channel"))
                return true
            }

            guard let chansForPSM = (channelsLock.withLock { channels[Int(channel.psm)] }) else {
                channelConnectedContinuation?.resume(
                    throwing: RuntimeError("channel opened but no channel manager found for PSM \(channel.psm)"))
                return true
            }
            do {
                let newCID = try chansForPSM.handleChannelDidOpen(didOpen: channel)
                channelConnectedContinuation?.resume(returning: newCID)
            } catch {
                channelConnectedContinuation?.resume(throwing: error)
                channelConnectedContinuation = nil
            }
            channelConnectedContinuation = nil
            return false
        }) {
            return
        }
    }

    public func peripheral(
        _ peripheral: CBPeripheral,
        didDiscoverServices error: (any Error)?
    ) {
        if (contLocks.withLock {
            if let error = error {
                connectedContinuation?.resume(throwing: error)
                connectedContinuation = nil
                return true
            }
            neededSvcDoneCount = peripheral.services?.count ?? 0
            if neededSvcDoneCount == 0 {
                connectedContinuation?.resume()
                connectedContinuation = nil
                return true
            }
            return false
        }) {
            return
        }
        peripheral.services?.forEach({ CBService in
            peripheral.discoverCharacteristics(nil, for: CBService)
        })
    }

    public func peripheral(
        _ peripheral: CBPeripheral,
        didDiscoverCharacteristicsFor service: CBService,
        error: (any Error)?
    ) {
        discoveredSvcDoneCount += 1

        if let error = error {
            debugPrint("error discovering characteristics for \(service.uuid.uuidString): \(error)")
        }
        if discoveredSvcDoneCount == neededSvcDoneCount {
            discoveredServices = peripheral.services?.map({ CBService in
                return ["id": CBService.uuid.uuidString,
                        "characteristics": CBService.characteristics?.map({ CBCharacteristic in
                            return ["id": CBCharacteristic.uuid.uuidString]
                        }) ?? []]
            }) ?? []
            contLocks.withLock {
                connectedContinuation?.resume()
                connectedContinuation = nil
            }
        }
    }

    public func peripheral(
        _ peripheral: CBPeripheral, didUpdateValueFor characteristic: CBCharacteristic, error: Error?) {
        if (contLocks.withLock {
            guard let conts = pendingCharReads[characteristic.uuid]  else {
                return true
            }

            conts.forEach { cont in
                if let error = error {
                    cont.resume(throwing: error)
                    return
                }
                guard let data = characteristic.value else {
                    cont.resume(throwing: RuntimeError("no data for characteristic"))
                    return
                }
                cont.resume(returning: data)
            }
            pendingCharReads[characteristic.uuid] = nil
            return false
        }) {
            return
        }
    }
}
