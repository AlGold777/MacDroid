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
            // Fail-closed: неизвестный источник не должен молча трактоваться как локальный Mac
            // (иначе операция может уйти не туда, куда ожидал пользователь).
            throw DecodingError.dataCorruptedError(
                in: container,
                debugDescription: "Неизвестный источник файла: \(raw)"
            )
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
    public let creationDate: Double?
    public var tags: [String]
    
    public init(
        id: String,
        name: String,
        path: String,
        size: UInt64,
        mtime: Double,
        isDirectory: Bool,
        source: FileSource = .localMac,
        creationDate: Double? = nil,
        tags: [String] = []
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
        self.creationDate = creationDate
        self.tags = tags
    }
    
    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.id = try container.decode(String.self, forKey: .id)
        let rawName = try container.decode(String.self, forKey: .name)
        self.name = rawName.utf8.allSatisfy({ $0 < 128 }) ? rawName : rawName.precomposedStringWithCanonicalMapping
        let rawPath = try container.decode(String.self, forKey: .path)
        self.path = rawPath.utf8.allSatisfy({ $0 < 128 }) ? rawPath : rawPath.precomposedStringWithCanonicalMapping
        self.size = try container.decode(UInt64.self, forKey: .size)
        self.mtime = try container.decode(Double.self, forKey: .mtime)
        self.isDirectory = try container.decode(Bool.self, forKey: .isDirectory)
        self.source = try container.decodeIfPresent(FileSource.self, forKey: .source) ?? .localMac
        self.creationDate = try container.decodeIfPresent(Double.self, forKey: .creationDate)
        self.tags = try container.decodeIfPresent([String].self, forKey: .tags) ?? []
    }
    
    public var fileType: String {
        if isDirectory {
            return ""
        }
        let ext = (name as NSString).pathExtension
        return ext.lowercased()
    }
    
    public var tagSortKey: String {
        return tags.first ?? ""
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
