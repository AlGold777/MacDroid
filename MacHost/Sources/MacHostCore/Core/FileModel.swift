import Foundation

public enum FileSource: String, CaseIterable, Identifiable, Sendable, Codable {
    case localMac = "Mac"
    case remotePhone = "Phone"
    
    public var id: String { self.rawValue }
    
    public var isRemote: Bool {
        return self == .remotePhone
    }
    
    public init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        let raw = try container.decode(String.self)
        if raw == "MacBook (Локально)" || raw == "MacBook" || raw == "Mac" || raw == "localMac" {
            self = .localMac
        } else if raw == "Xiaomi 14 Ultra (Wi-Fi/SFTP)" || raw == "Xiaomi 14" || raw == "Phone" || raw == "remotePhone" {
            self = .remotePhone
        } else if let s = FileSource(rawValue: raw) {
            self = s
        } else {
            self = .localMac
        }
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
        // Оптимизация: пропускаем NFC для чистых ASCII-строк
        self.name = name.utf8.allSatisfy({ $0 < 128 }) ? name : name.precomposedStringWithCanonicalMapping
        self.path = path.utf8.allSatisfy({ $0 < 128 }) ? path : path.precomposedStringWithCanonicalMapping
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
