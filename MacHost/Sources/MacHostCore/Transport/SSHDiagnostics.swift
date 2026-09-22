import Foundation

/// Continuously drains stderr so SSH cannot block on a full pipe.
final class SSHDiagnostics: @unchecked Sendable {
    private let lock = NSLock()
    private var bytes = Data()
    init(pipe: Pipe) {
        DispatchQueue.global(qos: .utility).async { [self] in
            while let chunk = try? pipe.fileHandleForReading.read(upToCount: 1024), !chunk.isEmpty {
                lock.lock()
                bytes.append(chunk)
                bytes = Data(bytes.suffix(8192))
                lock.unlock()
            }
        }
    }
    var message: String {
        lock.lock()
        defer { lock.unlock() }
        return String(decoding: bytes, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
