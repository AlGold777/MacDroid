import CryptoKit
import Darwin
import Foundation

public enum FileContentError: LocalizedError, Sendable {
    case directory(String)
    case unsupportedSource(String)
    case changed(String)
    case incompleteRead(String)

    public var errorDescription: String? {
        switch self {
        case .directory(let path): return "Нельзя вычислить хэш каталога: \(path)"
        case .unsupportedSource(let path): return "Неизвестный источник файла: \(path)"
        case .changed(let path): return "Файл изменился во время чтения: \(path)"
        case .incompleteRead(let path): return "Файл прочитан не полностью: \(path)"
        }
    }
}

/// Calculates SHA-256 directly from a local file or a streamed remote SFTP handle.
public struct FileContentService: Sendable {
    public static let chunkSize = 256 * 1024

    private let transport: TransportMultiplexer

    public init(transport: TransportMultiplexer) {
        self.transport = transport
    }

    public func digest(_ item: FileItem) async throws -> String {
        guard !item.isDirectory else { throw FileContentError.directory(item.path) }
        switch item.source {
        case .localMac:
            return try digestLocal(item)
        case .remotePhone:
            return try await transport.digestRemoteFile(
                at: item.path,
                expectedSize: item.size,
                expectedMtime: item.mtime
            )
        }
    }

    private func digestLocal(_ item: FileItem) throws -> String {
        let url = URL(fileURLWithPath: item.path)
        let before = try localFileStat(url.path, path: item.path)
        try validate(before, expectedSize: item.size, expectedMtime: item.mtime, path: item.path)

        let handle = try FileHandle(forReadingFrom: url)
        let opened = try descriptorStat(handle.fileDescriptor, path: item.path)
        guard opened == before else { throw FileContentError.changed(item.path) }
        var hasher = SHA256()
        var bytesRead: UInt64 = 0
        do {
            while true {
                try Task.checkCancellation()
                guard let chunk = try handle.read(upToCount: Self.chunkSize), !chunk.isEmpty else { break }
                hasher.update(data: chunk)
                bytesRead += UInt64(chunk.count)
            }
            try Task.checkCancellation()
            let after = try descriptorStat(handle.fileDescriptor, path: item.path)
            let pathAfter = try localFileStat(url.path, path: item.path)
            guard bytesRead == before.size,
                  after == before,
                  pathAfter == before else {
                throw FileContentError.changed(item.path)
            }
            try handle.close()
            return Self.hex(hasher.finalize())
        } catch {
            try? handle.close()
            throw error
        }
    }

    private struct LocalStat: Equatable {
        let device: dev_t
        let inode: ino_t
        let size: UInt64
        let mtimeSeconds: Int64
        let mtimeNanoseconds: Int64
    }

    private func localFileStat(_ path: String, path itemPath: String) throws -> LocalStat {
        var info = stat()
        guard Darwin.fstatat(AT_FDCWD, path, &info, 0) == 0,
              info.st_mode & mode_t(S_IFMT) == mode_t(S_IFREG),
              info.st_size >= 0 else {
            throw FileContentError.changed(itemPath)
        }
        return makeLocalStat(info)
    }

    private func descriptorStat(_ descriptor: Int32, path: String) throws -> LocalStat {
        var info = stat()
        guard Darwin.fstat(descriptor, &info) == 0,
              info.st_mode & mode_t(S_IFMT) == mode_t(S_IFREG),
              info.st_size >= 0 else {
            throw FileContentError.changed(path)
        }
        return makeLocalStat(info)
    }

    private func makeLocalStat(_ info: stat) -> LocalStat {
        LocalStat(device: info.st_dev, inode: info.st_ino, size: UInt64(info.st_size),
                  mtimeSeconds: Int64(info.st_mtimespec.tv_sec),
                  mtimeNanoseconds: Int64(info.st_mtimespec.tv_nsec))
    }

    private func validate(
        _ stat: LocalStat,
        expectedSize: UInt64,
        expectedMtime: Double,
        path: String
    ) throws {
        let mtime = Double(stat.mtimeSeconds) + Double(stat.mtimeNanoseconds) / 1_000_000_000
        guard stat.size == expectedSize, abs(mtime - expectedMtime) < 0.001 else {
            throw FileContentError.changed(path)
        }
    }

    private static func hex(_ digest: SHA256.Digest) -> String {
        digest.map { String(format: "%02x", $0) }.joined()
    }
}
