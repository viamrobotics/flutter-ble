import CoreBluetooth

extension Sequence {
    func asyncForEach(
        _ operation: (Element) async throws -> Void
    ) async rethrows {
        for element in self {
            try await operation(element)
        }
    }
}

struct RuntimeError: LocalizedError {
    let description: String

    init(_ description: String) {
        self.description = description
    }

    var errorDescription: String? {
        description
    }
}

// This lets us write data more easily and wraps up unsafe logic.
extension OutputStream {
    func write(_ data: Data) -> Int {
        return data.withUnsafeBytes({ (rawBufferPointer: UnsafeRawBufferPointer) -> Int in
            let bufferPointer = rawBufferPointer.bindMemory(to: UInt8.self)
            // This force unwrap is okay
            return Int(self.write(bufferPointer.baseAddress!, maxLength: data.count))
        })
    }
}

// This lets us read data more easily up to the amount that we want.
extension InputStream {
    func read(_ maxRead: Int) -> (Int, Data?) {
        let data = NSMutableData(length: maxRead)!
        while true {
            let bytesRead = self.read(data.mutableBytes, maxLength: data.count)
            if bytesRead <= 0 {
                return (bytesRead, nil)
            }
            return (bytesRead, data.subdata(with: NSRange(0..<bytesRead)))
        }
    }
}

func makeAdapterState(state: CBManagerState) -> [String: NSObject] {
    let updatatedValue = powerStateFromManager(state)
    let dataToSend = ["state": NSNumber(value: updatatedValue)]
    return dataToSend
}

func powerStateFromManager(_ state: CBManagerState) -> Int32 {
    return switch state {
    case .unknown:
        0
    case .resetting:
        1
    case .unsupported:
        2
    case .unauthorized:
        3
    case .poweredOff:
        4
    case .poweredOn:
        5
    default:
        0
    }
}
