import CoreBluetooth
import Foundation

/// An L2CAP channel manager is responsible for keeping track of multiple channels on top of a single PSM.
/// The multiplexing is done by the OS, not us, but we need to keep track of our own channel IDs since
/// we are not provided them. This manager is mostly functioning on the peripheral side considering
/// centrals are not yet able to connect to the same PSM more than once (don't know why).
public class L2CAPChannelManager {

    let psm: Int
    var channels: [Int: L2CAPChannel] = [:] // cid:chan
    var channelsLock: NSLock = NSLock()
    var nextCID = 0 // this is our own concept of CID

    // this is just for peripherals
    private var unpublishedContinuation: CheckedContinuation<Void, Error>?
    private var unpublishedContinuationLock: NSLock = NSLock()

    var isClosed: Bool = false
    var isClosedLock: NSLock = NSLock()

    init(psm: Int) {
        self.psm = psm
    }

    public func getChannel(cid: Int) -> L2CAPChannel? {
        return channelsLock.withLock {
            self.channels[cid]
        }
    }

    public func startUnpublish(withContinuation continuation: CheckedContinuation<Void, Error>) -> Bool {
        return unpublishedContinuationLock.withLock {
            if unpublishedContinuation != nil {
                return false
            }
            unpublishedContinuation = continuation
            return true
        }
    }

    public func takeUnpublishedContinuation() -> CheckedContinuation<Void, Error>? {
        unpublishedContinuationLock.withLock {
            let ref = unpublishedContinuation
            unpublishedContinuation = nil
            return ref
        }
    }

    func handleChannelDidOpen(didOpen channel: CBL2CAPChannel) throws -> Int {
        return try channelsLock.withLock {
            // increment at least once
            for _ in 0..<self.channels.count+1 {
                let (result, didOverflow) = nextCID.addingReportingOverflow(1)
                if didOverflow {
                    nextCID = 0
                } else {
                    nextCID = result
                }
                if self.channels[nextCID] == nil {
                    break
                }
            }

            if self.channels[nextCID] != nil {
                throw RuntimeError("too many channels open")
            }
            let thisCID = nextCID
            let chan = L2CAPChannel(channel: channel, onClose: {
                self.channelsLock.withLock {
                    self.channels[thisCID] = nil
                }
            })
            channels[thisCID] = chan

            channel.inputStream.open()
            channel.outputStream.open()

            return thisCID
        }
    }

    public func close() {
        if (isClosedLock.withLock {
            if isClosed {
                return true
            }
            isClosed = true
            return false
        }) {
            return
        }

        var readCopy: [L2CAPChannel] = []
        channelsLock.withLock {
            readCopy = channels.values.map { $0 }
        }
        readCopy.forEach { chan in
            do {
                try chan.close()
            } catch {
                debugPrint("error closing channel for internal cid \(chan.channel.psm): \(error)")
            }
        }
        channelsLock.withLock {
            channels.removeAll()
        }
        return
    }
}
