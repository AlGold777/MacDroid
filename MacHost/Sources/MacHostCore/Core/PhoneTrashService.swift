import Foundation

/// Minimal remote filesystem operations required by the recoverable phone trash.
public protocol PhoneTrashStorage: Sendable {
    func list(_ path: String) async throws -> [FileItem]
    func exists(_ path: String) async throws -> Bool
    func mkdir(_ path: String) async throws
    func rename(_ source: String, _ destination: String) async throws
    func readSmallFile(_ path: String, maxBytes: Int) async throws -> Data
    func writeExclusive(_ path: String, data: Data) async throws
    func deleteFile(_ path: String) async throws
    func deletePermanent(_ path: String) async throws
    func removeEmptyDirectory(_ path: String) async throws
}

public extension PhoneTrashStorage {
    /// Fake stores may omit cleanup; leaving an empty UUID directory is recoverable.
    func removeEmptyDirectory(_ path: String) async throws {}

    /// Compatibility default for simple stores. Production SFTP uses REMOVE only.
    func deleteFile(_ path: String) async throws {
        try await deletePermanent(path)
    }
}

/// A validated record describing one item in the phone trash.
public struct PhoneTrashEntry: Identifiable, Codable, Sendable, Hashable {
    public let id: String
    public let originalPath: String
    public let deletedAt: Date
    public let isDirectory: Bool
    public let schemaVersion: Int

    public var name: String { (originalPath as NSString).lastPathComponent }

    public var trashRoot: String {
        get throws { try PhoneTrashService.volumeRoot(for: originalPath) + "/.MacDroidTrash" }
    }

    public var entryPath: String {
        get throws { try trashRoot + "/" + PhoneTrashService.validatedUUID(id) }
    }

    public init(id: String, originalPath: String, deletedAt: Date, isDirectory: Bool, schemaVersion: Int = 1) {
        self.id = id
        self.originalPath = originalPath
        self.deletedAt = deletedAt
        self.isDirectory = isDirectory
        self.schemaVersion = schemaVersion
    }
}

public enum PhoneTrashError: LocalizedError, Sendable {
    case invalidPath(String)
    case volumeRootCannotBeTrashed(String)
    case unsupportedVolume(String)
    case invalidEntry(String)
    case damagedEntry(String)
    case destinationExists(String)
    case destinationParentMissing(String)
    case sourceNotFound(String)
    case fileTooLarge(String)

    public var errorDescription: String? {
        switch self {
        case .invalidPath(let path): return "Недопустимый путь для корзины телефона: \(path)"
        case .volumeRootCannotBeTrashed(let path): return "Корень тома нельзя переместить в корзину: \(path)"
        case .unsupportedVolume(let path): return "Неизвестный корень тома телефона: \(path)"
        case .invalidEntry(let id): return "Недопустимая запись корзины: \(id)"
        case .damagedEntry(let path): return "Повреждённая запись корзины телефона: \(path)"
        case .destinationExists(let path): return "Путь восстановления уже занят: \(path)"
        case .destinationParentMissing(let path): return "Папка для восстановления не существует: \(path)"
        case .sourceNotFound(let path): return "Файл или папка не найдены: \(path)"
        case .fileTooLarge(let path): return "Файл метаданных корзины слишком большой: \(path)"
        }
    }
}

/// Implements metadata-first moves into a per-volume hidden directory on the phone.
public struct PhoneTrashService: Sendable {
    public static let directoryName = ".MacDroidTrash"
    public static let metadataFileName = "info.json"
    public static let payloadName = "payload"
    public static let maximumMetadataBytes = 64 * 1024

    private let storage: any PhoneTrashStorage

    public init(storage: any PhoneTrashStorage) {
        self.storage = storage
    }

    /// Resolves supported Android storage paths to their volume root.
    public static func volumeRoot(for path: String) throws -> String {
        let normalized = try normalizedAbsolutePath(path)
        let components = normalized.split(separator: "/").map(String.init)
        if components.first == "sdcard" {
            return "/storage/emulated/0"
        }
        guard components.first == "storage" else {
            throw PhoneTrashError.unsupportedVolume(path)
        }
        if components.count >= 3, components[1] == "emulated", components[2] == "0" {
            return "/storage/emulated/0"
        }
        guard components.count >= 2, components[1] != "emulated", components[1] != "self",
              isSupportedVolumeID(components[1]) else {
            throw PhoneTrashError.unsupportedVolume(path)
        }
        return "/storage/\(components[1])"
    }

    public func moveToTrash(at path: String, beforeMove: @Sendable () async throws -> Void = {}) async throws -> PhoneTrashEntry {
        let originalPath = try Self.validatedSourcePath(path)
        let volumeRoot = try Self.volumeRoot(for: originalPath)
        let parentPath = (originalPath as NSString).deletingLastPathComponent
        guard parentPath != originalPath else { throw PhoneTrashError.volumeRootCannotBeTrashed(path) }

        let sourceItems = try await storage.list(parentPath)
        guard let sourceItem = sourceItems.first(where: { Self.samePath($0.path, originalPath) }) else {
            throw PhoneTrashError.sourceNotFound(originalPath)
        }

        let trashRoot = volumeRoot + "/" + Self.directoryName
        if let rootEntry = try await findChild(Self.directoryName, in: volumeRoot) {
            guard rootEntry.isDirectory else { throw PhoneTrashError.damagedEntry(trashRoot) }
            _ = try await storage.list(trashRoot)
        } else {
            try await storage.mkdir(trashRoot)
            guard let createdRoot = try await findChild(Self.directoryName, in: volumeRoot), createdRoot.isDirectory else {
                throw PhoneTrashError.damagedEntry(trashRoot)
            }
        }

        let id = UUID().uuidString.lowercased()
        let entry = PhoneTrashEntry(id: id, originalPath: originalPath, deletedAt: Date(), isDirectory: sourceItem.isDirectory)
        let entryPath = try entry.entryPath
        try await storage.mkdir(entryPath)
        guard let createdEntry = try await findChild(id, in: trashRoot), createdEntry.isDirectory else {
            throw PhoneTrashError.damagedEntry(entryPath)
        }

        let metadataURL = entryPath + "/" + Self.metadataFileName
        let payloadPath = entryPath + "/" + Self.payloadName
        let metadata = try JSONEncoder().encode(entry)
        do {
            try await storage.writeExclusive(metadataURL, data: metadata)
        } catch {
            // Do not recursively remove a directory after a failed exclusive create.
            // It may contain a pre-existing or concurrently-created object.
            throw error
        }

        do {
            guard let currentRoot = try await findChild(Self.directoryName, in: volumeRoot), currentRoot.isDirectory,
                  let currentEntry = try await findChild(id, in: trashRoot), currentEntry.isDirectory else {
                throw PhoneTrashError.damagedEntry(entryPath)
            }
            try await beforeMove()
            try await storage.rename(originalPath, payloadPath)
        } catch {
            // A lost SFTP response can make the rename outcome ambiguous. Keep the
            // metadata unless we can establish that the source remains and payload does not.
            if (try? await storage.exists(originalPath)) == true,
               (try? await storage.exists(payloadPath)) == false {
                await cleanupEmptyEntry(entryPath, metadataPath: metadataURL, expectedMetadata: metadata)
            }
            throw error
        }
        return entry
    }

    public func entries(volumePath: String) async throws -> [PhoneTrashEntry] {
        let root = try Self.volumeRoot(for: volumePath)
        let trashRoot = root + "/" + Self.directoryName
        guard let rootEntry = try await findChild(Self.directoryName, in: root) else { return [] }
        guard rootEntry.isDirectory else { throw PhoneTrashError.damagedEntry(trashRoot) }
        let children = try await storage.list(trashRoot)
        var result: [PhoneTrashEntry] = []
        result.reserveCapacity(children.count)
        for child in children {
            guard child.isDirectory,
                  let uuid = UUID(uuidString: child.name),
                  uuid.uuidString.lowercased() == child.name else {
                continue
            }
            let entryPath = trashRoot + "/" + child.name
            guard let payload = try await findChild(Self.payloadName, in: entryPath) else {
                // Metadata-first writes can leave an empty or partial record if the
                // connection fails before the source rename. No user payload is here.
                continue
            }
            let entry = try await loadValidatedEntry(id: child.name, expectedRoot: root)
            guard payload.isDirectory == entry.isDirectory else {
                throw PhoneTrashError.damagedEntry(child.path)
            }
            result.append(entry)
        }
        return result.sorted { $0.deletedAt > $1.deletedAt }
    }

    public func restore(_ entry: PhoneTrashEntry) async throws {
        let root = try Self.volumeRoot(for: entry.originalPath)
        let stored = try await loadValidatedEntry(id: entry.id, expectedRoot: root)
        let requestedPath = try Self.validatedSourcePath(entry.originalPath)
        guard stored.originalPath == requestedPath, stored.isDirectory == entry.isDirectory else {
            throw PhoneTrashError.invalidEntry(entry.id)
        }

        let parentPath = (stored.originalPath as NSString).deletingLastPathComponent
        guard try await storage.exists(parentPath) else {
            throw PhoneTrashError.destinationParentMissing(parentPath)
        }
        // list() distinguishes a directory parent from a regular file and propagates
        // permission/read failures instead of treating them as a missing parent.
        _ = try await storage.list(parentPath)
        guard try await findChild((stored.originalPath as NSString).lastPathComponent, in: parentPath) == nil else {
            throw PhoneTrashError.destinationExists(stored.originalPath)
        }

        let entryPath = try stored.entryPath
        let payloadPath = entryPath + "/" + Self.payloadName
        guard let payload = try await findChild(Self.payloadName, in: entryPath),
              payload.isDirectory == stored.isDirectory else { throw PhoneTrashError.damagedEntry(entryPath) }
        try await storage.rename(payloadPath, stored.originalPath)
        // The move is committed. Cleanup is best-effort and must not report a false
        // restore failure after the payload has returned to its original location.
        await cleanupEmptyEntry(entryPath, metadataPath: entryPath + "/" + Self.metadataFileName)
    }

    public func permanentlyDelete(_ entry: PhoneTrashEntry) async throws {
        let root = try Self.volumeRoot(for: entry.originalPath)
        let stored = try await loadValidatedEntry(id: entry.id, expectedRoot: root)
        let requestedPath = try Self.validatedSourcePath(entry.originalPath)
        guard stored.originalPath == requestedPath, stored.isDirectory == entry.isDirectory else {
            throw PhoneTrashError.invalidEntry(entry.id)
        }
        let entryPath = try stored.entryPath
        let payloadPath = entryPath + "/" + Self.payloadName
        guard let payload = try await findChild(Self.payloadName, in: entryPath),
              payload.isDirectory == stored.isDirectory else { throw PhoneTrashError.damagedEntry(entryPath) }
        try await storage.deletePermanent(payloadPath)
        // Once the payload is gone, cleanup cannot make the purge less safe.
        await cleanupEmptyEntry(entryPath, metadataPath: entryPath + "/" + Self.metadataFileName)
    }

    private func loadValidatedEntry(id: String, expectedRoot: String) async throws -> PhoneTrashEntry {
        let safeID = try Self.validatedUUID(id)
        let trashRoot = expectedRoot + "/" + Self.directoryName
        guard let rootEntry = try await findChild(Self.directoryName, in: expectedRoot), rootEntry.isDirectory else {
            throw PhoneTrashError.damagedEntry(trashRoot)
        }
        let entryPath = trashRoot + "/" + safeID
        guard let entryDirectory = try await findChild(safeID, in: trashRoot), entryDirectory.isDirectory else {
            throw PhoneTrashError.damagedEntry(entryPath)
        }
        let metadataPath = entryPath + "/" + Self.metadataFileName
        guard let metadataItem = try await findChild(Self.metadataFileName, in: entryPath), !metadataItem.isDirectory else {
            throw PhoneTrashError.damagedEntry(metadataPath)
        }
        let data = try await storage.readSmallFile(metadataPath, maxBytes: Self.maximumMetadataBytes)
        guard data.count <= Self.maximumMetadataBytes else { throw PhoneTrashError.fileTooLarge(metadataPath) }
        let entry: PhoneTrashEntry
        do {
            entry = try JSONDecoder().decode(PhoneTrashEntry.self, from: data)
        } catch {
            throw PhoneTrashError.damagedEntry(metadataPath)
        }
        guard try Self.validatedUUID(entry.id) == safeID,
              try Self.volumeRoot(for: entry.originalPath) == expectedRoot,
              try Self.validatedSourcePath(entry.originalPath) == entry.originalPath,
              entry.schemaVersion == 1 else {
            throw PhoneTrashError.damagedEntry(metadataPath)
        }
        return entry
    }

    private func findChild(_ name: String, in directory: String) async throws -> FileItem? {
        let children = try await storage.list(directory)
        return children.first { $0.name == name }
    }

    private func cleanupEmptyEntry(_ entryPath: String, metadataPath: String, expectedMetadata: Data? = nil) async {
        do {
            let trashRoot = (entryPath as NSString).deletingLastPathComponent
            let volumeRoot = (trashRoot as NSString).deletingLastPathComponent
            let entryID = (entryPath as NSString).lastPathComponent
            guard let rootItem = try await findChild(Self.directoryName, in: volumeRoot), rootItem.isDirectory,
                  let entryItem = try await findChild(entryID, in: trashRoot), entryItem.isDirectory else { return }
            let children = try await storage.list(entryPath)
            guard children.count == 1, children[0].name == Self.metadataFileName,
                  !children[0].isDirectory else { return }
            if let expectedMetadata {
                let existing = try await storage.readSmallFile(metadataPath, maxBytes: Self.maximumMetadataBytes)
                guard existing == expectedMetadata else { return }
            }
            guard let currentRoot = try await findChild(Self.directoryName, in: volumeRoot), currentRoot.isDirectory,
                  let currentEntry = try await findChild(entryID, in: trashRoot), currentEntry.isDirectory else { return }
            try await storage.deleteFile(metadataPath)
            let remaining = try await storage.list(entryPath)
            guard remaining.isEmpty else { return }
            guard let finalRoot = try await findChild(Self.directoryName, in: volumeRoot), finalRoot.isDirectory,
                  let finalEntry = try await findChild(entryID, in: trashRoot), finalEntry.isDirectory else { return }
            try await storage.removeEmptyDirectory(entryPath)
        } catch {
            // Cleanup is deliberately best-effort after a committed move.
        }
    }

    fileprivate static func validatedUUID(_ value: String) throws -> String {
        guard let uuid = UUID(uuidString: value), uuid.uuidString.lowercased() == value.lowercased() else {
            throw PhoneTrashError.invalidEntry(value)
        }
        return uuid.uuidString.lowercased()
    }

    private static func validatedSourcePath(_ path: String) throws -> String {
        var normalized = try normalizedAbsolutePath(path)
        if normalized == "/sdcard" || normalized.hasPrefix("/sdcard/") {
            normalized = "/storage/emulated/0" + String(normalized.dropFirst("/sdcard".count))
        }
        let root = try volumeRoot(for: normalized)
        guard normalized != root else { throw PhoneTrashError.volumeRootCannotBeTrashed(path) }
        let components = normalized.split(separator: "/").map(String.init)
        guard !components.contains(directoryName) else { throw PhoneTrashError.invalidPath(path) }
        guard normalized.hasPrefix(root + "/") else { throw PhoneTrashError.invalidPath(path) }
        return normalized
    }

    private static func normalizedAbsolutePath(_ path: String) throws -> String {
        let value = path.precomposedStringWithCanonicalMapping
        guard value.hasPrefix("/"), !value.contains("\0") else { throw PhoneTrashError.invalidPath(path) }
        let components = value.split(separator: "/", omittingEmptySubsequences: false).dropFirst().map(String.init)
        guard !components.contains("."), !components.contains("..") else { throw PhoneTrashError.invalidPath(path) }
        let clean = components.filter { !$0.isEmpty }
        return clean.isEmpty ? "/" : "/" + clean.joined(separator: "/")
    }

    private static func samePath(_ lhs: String, _ rhs: String) -> Bool {
        (try? normalizedAbsolutePath(lhs)) == (try? normalizedAbsolutePath(rhs))
    }

    private static func isSupportedVolumeID(_ value: String) -> Bool {
        let parts = value.split(separator: "-", omittingEmptySubsequences: false)
        if parts.count == 2, parts[0].count == 4, parts[1].count == 4 {
            return parts.allSatisfy { $0.allSatisfy(\.isHexDigit) }
        }
        if parts.count == 5, parts.map(\.count) == [8, 4, 4, 4, 12] {
            return parts.allSatisfy { $0.allSatisfy(\.isHexDigit) }
        }
        return false
    }
}
