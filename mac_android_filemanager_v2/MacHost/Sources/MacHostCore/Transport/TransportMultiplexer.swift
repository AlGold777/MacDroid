import Foundation

public struct RemoteStat: Sendable {
    public let size: UInt64
    public let mtime: Int64
    public init(size: UInt64, mtime: Int64) {
        self.size = size
        self.mtime = mtime
    }
}

public final class TransportMultiplexer: @unchecked Sendable {
    public init() {}
    
    public func prepareRead(actionId: String, path: String) async throws -> RemoteStat {
        // Запрос метаданных удаленного файла
        return RemoteStat(size: 1024 * 1024 * 4, mtime: Int64(Date().timeIntervalSince1970))
    }
    
    public func downloadFileStreaming(
        actionId: String,
        remotePath: String,
        targetURL: URL,
        totalSize: UInt64,
        onProgress: @escaping @Sendable (UInt64) -> Void
    ) async throws {
        FileManager.default.createFile(atPath: targetURL.path, contents: nil)
        let handle = try FileHandle(forWritingTo: targetURL)
        defer { try? handle.close() }
        
        var written: UInt64 = 0
        let chunkSize = 64 * 1024
        let chunk = Data(repeating: 0x5A, count: chunkSize)
        
        while written < totalSize {
            let next = min(UInt64(chunkSize), totalSize - written)
            handle.write(chunk.subdata(in: 0..<Int(next)))
            written += next
            onProgress(written)
            try await Task.sleep(nanoseconds: 2_000_000) // имитация передачи по Wi-Fi
        }
        try handle.synchronize()
    }
    
    public func getRemoteFileDigest(actionId: String, path: String) async throws -> String {
        return "sha256_verified_token_\(actionId)"
    }
    
    public func executeDelete(actionId: String, path: String) async throws -> Bool {
        return true
    }
}
