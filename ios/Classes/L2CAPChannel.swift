import CoreBluetooth
import Foundation

/// This is a small wrapper around an L2CAP COC that allows for async reading and writing.
/// All reads and writes are serialized.
public class L2CAPChannel {
    private let readDataQueue = DispatchQueue(
        label: "BLE_READ_QUEUE", qos: .userInitiated, attributes: [], autoreleaseFrequency: .workItem, target: nil)
    private let writeDataQueue = DispatchQueue(
        label: "BLE_WRITE_QUEUE", qos: .userInitiated, attributes: [], autoreleaseFrequency: .workItem, target: nil)
    public var onClose: (() throws -> Void)

    public var channel: CBL2CAPChannel

    private var isClosed = false
    var isClosedLock: NSLock = NSLock()

    init(channel: CBL2CAPChannel, onClose: @escaping (() throws -> Void)) {
        self.channel = channel
        self.onClose = onClose
    }

    // Note: This assumes the OutputStream.write is blocking/serial.
    public func write(data: Data) async throws {
        guard (isClosedLock.withLock { !isClosed }) else {
            throw RuntimeError("channel closed")
        }
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            self.writeDataQueue.async {
                let bytesWritten =  self.channel.outputStream.write(data)
                if bytesWritten == -1 {
                    switch self.channel.outputStream.streamStatus {
                    case .atEnd:
                        continuation.resume(throwing: RuntimeError("channel closed"))
                    case .closed:
                        continuation.resume(throwing: RuntimeError("channel closed"))
                    case .error:
                        continuation.resume(
                            throwing: self.channel.outputStream.streamError ?? RuntimeError("write stream error"))
                    default:
                        continuation.resume(
                            throwing: RuntimeError(
                                "write failed for unknown reason \(self.channel.outputStream.streamStatus)"))
                    }
                    return
                }
                continuation.resume()
            }
        }
    }

    // Note: This assumes the InputStream.read is blocking/serial.
    public func read(maxRead: Int) async throws -> Data? {
        guard (isClosedLock.withLock { !isClosed }) else {
            throw RuntimeError("channel closed")
        }
        return try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Data?, Error>) in
            self.readDataQueue.async {
                let (bytesRead, data) =  self.channel.inputStream.read(maxRead)
                if bytesRead == -1 {
                    switch self.channel.inputStream.streamStatus {
                    case .atEnd:
                        continuation.resume(returning: nil)
                    case .closed:
                        continuation.resume(throwing: RuntimeError("channel closed"))
                    case .error:
                        continuation.resume(
                            throwing: self.channel.inputStream.streamError ?? RuntimeError("read stream error"))
                    default:
                        break
                    }
                    return
                }
                if bytesRead == 0 {
                    continuation.resume(returning: nil)
                    return
                }
                guard let data else {
                    continuation.resume(throwing: RuntimeError("invariant: expected data to be set"))
                    return
                }
                continuation.resume(returning: data)
            }
        }
    }

    public func close() throws {
        if (isClosedLock.withLock {
            if isClosed {
                return true
            }
            isClosed = true
            return false
        }) {
            return
        }

        channel.outputStream.close()
        channel.inputStream.close()
        try onClose()
    }
}
