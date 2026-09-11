import Foundation

public enum FileSource: String, CaseIterable, Identifiable, Sendable, Codable {
    case localMac = "MacBook (Локально)"
    case remotePhone = "Xiaomi 14 Ultra (Wi-Fi/SFTP)"
    
    public var id: String { self.rawValue }
    
    public var isRemote: Bool {
        return self == .remotePhone
    }
}

public struct FileItem: Identifiable, Hashable, Sendable, Codable {
    public let id: String
    public let name: String
    public let path: String
    public let size: UInt64
    public let mtime: Double
    public let isDirectory: Bool
    public let source: FileSource
    
    public init(
        id: String,
        name: String,
        path: String,
        size: UInt64,
        mtime: Double,
        isDirectory: Bool,
        source: FileSource = .localMac
    ) {
        self.id = id
        // Гарантируем каноническую нормализацию Unicode (NFC)
        self.name = name.precomposedStringWithCanonicalMapping
        self.path = path.precomposedStringWithCanonicalMapping
        self.size = size
        self.mtime = mtime
        self.isDirectory = isDirectory
        self.source = source
    }
}

public enum ItemState: String, Codable, Sendable {
    case planned = "PLANNED"
    case running = "RUNNING"
    case committing = "COMMITTING"
    case completed = "COMPLETED"
    case indeterminate = "INDETERMINATE"
    case failed = "FAILED"
}
