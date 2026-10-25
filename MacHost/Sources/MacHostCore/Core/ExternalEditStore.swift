import CryptoKit
import Darwin
import Foundation

public struct ExternalEditSession: Codable, Identifiable, Sendable {
    public let id: UUID
    public let deviceFingerprint: String
    public let remotePath: String
    public let fileName: String
    public let originalDigest: String
    public var savedDigest: String
    public var lastSavedPath: String?
    /// Persisted before sending anything. A crash must not turn an unknown outcome into success.
    public var pendingRemotePath: String?
    public var previousUnconfirmedPaths: [String] = []
    public let createdAt: Date
}

public struct ExternalEditSnapshot: Sendable {
    public let url: URL
    public let digest: String
    public let remotePath: String
}

public enum ExternalEditError: LocalizedError {
    case invalidName, missingSession, wrongDevice, unavailable, changed, invalidRegistry
    case uncertain(String)

    public var errorDescription: String? {
        switch self {
        case .invalidName: return "Недопустимое имя рабочей копии"
        case .missingSession: return "Рабочая копия не найдена"
        case .wrongDevice: return "Подключите тот же телефон с тем же закреплённым SSH-ключом"
        case .unavailable: return "Нет доступного SFTP-канала"
        case .changed: return "Файл меняется во время чтения. Сохраните его в редакторе и повторите проверку."
        case .invalidRegistry: return "Реестр рабочих копий повреждён. Файлы сохранены в Application Support/MacDroidCommander/ExternalEdits; реестр не перезаписан."
        case .uncertain(let path): return "Исход сохранения не подтверждён. Проверьте файл на телефоне: \(path). Локальные изменения сохранены."
        }
    }
}

/// Disk work is serialized on this actor, never on the UI thread. No automatic deletion:
/// an external editor may save a working copy again even after an upload completes.
public actor ExternalEditStore {
    public let root: URL
    private var loaded = false
    private var sessions: [ExternalEditSession] = []

    public init(root: URL? = nil) {
        self.root = root ?? FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("MacDroidCommander/ExternalEdits", isDirectory: true)
    }

    public func list() throws -> [ExternalEditSession] {
        try load()
        return sessions
    }

    public func existing(deviceFingerprint: String, remotePath: String) throws -> ExternalEditSession? {
        try load()
        return sessions.first { $0.deviceFingerprint == deviceFingerprint && $0.remotePath == remotePath }
    }

    public func workingURL(_ session: ExternalEditSession) -> URL {
        root.appendingPathComponent(session.id.uuidString).appendingPathComponent("working")
            .appendingPathComponent(session.fileName)
    }

    public func allocate(fileName: String) throws -> (UUID, URL) {
        try load()
        try Self.validateName(fileName)
        let id = UUID()
        let directory = root.appendingPathComponent(id.uuidString).appendingPathComponent("working")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true,
                                                attributes: [.posixPermissions: 0o700])
        return (id, directory.appendingPathComponent(fileName))
    }

    public func register(id: UUID, fileName: String, remotePath: String,
                         deviceFingerprint: String) throws -> ExternalEditSession {
        try load()
        try Self.validateName(fileName)
        let url = root.appendingPathComponent(id.uuidString).appendingPathComponent("working").appendingPathComponent(fileName)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
        let digest = try Self.digest(url)
        let session = ExternalEditSession(id: id, deviceFingerprint: deviceFingerprint, remotePath: remotePath,
                                          fileName: fileName, originalDigest: digest, savedDigest: digest,
                                          createdAt: Date())
        var updated = sessions
        updated.append(session)
        try persist(updated)
        sessions = updated
        return session
    }

    public func digestFile(_ url: URL) throws -> String {
        try Self.digest(url)
    }

    public func currentDigest(_ session: ExternalEditSession) throws -> String {
        try Self.digest(workingURL(session))
    }

    /// The immutable upload snapshot survives a crash for recovery. It is never opened in an editor.
    public func snapshot(_ id: UUID) throws -> ExternalEditSnapshot {
        try load()
        guard let session = sessions.first(where: { $0.id == id }) else { throw ExternalEditError.missingSession }
        let source = workingURL(session)
        let token = UUID().uuidString.lowercased()
        let directory = root.appendingPathComponent(id.uuidString).appendingPathComponent("snapshots/\(token)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true,
                                                attributes: [.posixPermissions: 0o700])
        let target = directory.appendingPathComponent(session.fileName)
        var coordinationError: NSError?
        var copyError: Error?
        NSFileCoordinator().coordinate(readingItemAt: source, options: .withoutChanges, error: &coordinationError) { url in
            do {
                let before = try Self.digest(url)
                try FileManager.default.copyItem(at: url, to: target)
                guard try Self.digest(target) == before, try Self.digest(url) == before else { throw ExternalEditError.changed }
                try FileManager.default.setAttributes([.posixPermissions: 0o400], ofItemAtPath: target.path)
            } catch { copyError = error }
        }
        if let error = coordinationError { throw error }
        if let error = copyError { throw error }
        let name = Self.copyName(session.fileName, token: token)
        let parent = (session.remotePath as NSString).deletingLastPathComponent
        let remotePath = (parent as NSString).appendingPathComponent(name)
        return ExternalEditSnapshot(url: target, digest: try Self.digest(target), remotePath: remotePath)
    }

    public func beginUpload(_ id: UUID, remotePath: String) throws {
        try update(id) {
            if let previous = $0.pendingRemotePath { $0.previousUnconfirmedPaths.append(previous) }
            $0.pendingRemotePath = remotePath
        }
    }

    public func completeUpload(_ id: UUID, snapshot: ExternalEditSnapshot) throws {
        try update(id) {
            $0.savedDigest = snapshot.digest
            $0.lastSavedPath = snapshot.remotePath
            $0.pendingRemotePath = nil
        }
    }

    private func update(_ id: UUID, mutation: (inout ExternalEditSession) -> Void) throws {
        try load()
        guard let index = sessions.firstIndex(where: { $0.id == id }) else { throw ExternalEditError.missingSession }
        var updated = sessions
        mutation(&updated[index])
        try persist(updated)
        sessions = updated
    }

    private func load() throws {
        guard !loaded else { return }
        let registry = root.appendingPathComponent("sessions.json")
        if FileManager.default.fileExists(atPath: registry.path) {
            do {
                let decoded = try JSONDecoder().decode([ExternalEditSession].self, from: Data(contentsOf: registry))
                guard Set(decoded.map(\.id)).count == decoded.count else { throw ExternalEditError.invalidRegistry }
                for session in decoded {
                    try Self.validateName(session.fileName)
                    guard !session.deviceFingerprint.isEmpty, session.remotePath.hasPrefix("/") else {
                        throw ExternalEditError.invalidRegistry
                    }
                }
                sessions = decoded
            } catch { throw ExternalEditError.invalidRegistry }
        }
        loaded = true
    }

    private func persist(_ updated: [ExternalEditSession]) throws {
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true,
                                                attributes: [.posixPermissions: 0o700])
        try JSONEncoder().encode(updated).write(to: root.appendingPathComponent("sessions.json"), options: .atomic)
    }

    private static func validateName(_ name: String) throws {
        guard !name.isEmpty, name != ".", name != "..", !name.contains("/"), !name.contains("\0") else {
            throw ExternalEditError.invalidName
        }
    }

    public static func copyName(_ fileName: String, token: String) -> String {
        var ext = (fileName as NSString).pathExtension
        if ext.utf8.count > 32 { ext = "" }
        var base = (fileName as NSString).deletingPathExtension
        while base.utf8.count > 160 { base.removeLast() }
        return "\(base).edited-\(token)" + (ext.isEmpty ? "" : ".\(ext)")
    }

    /// Includes inode, nanosecond timestamps and a second path stat to reject atomic replacement.
    public static func digest(_ url: URL) throws -> String {
        var before = stat()
        guard lstat(url.path, &before) == 0, before.st_mode & S_IFMT == S_IFREG else {
            throw ExternalEditError.changed
        }
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        var opened = stat()
        guard fstat(handle.fileDescriptor, &opened) == 0, same(before, opened) else { throw ExternalEditError.changed }
        var hasher = SHA256()
        var count: Int64 = 0
        while let data = try handle.read(upToCount: 256 * 1024), !data.isEmpty {
            hasher.update(data: data)
            count += Int64(data.count)
        }
        var after = stat(), pathAfter = stat()
        guard fstat(handle.fileDescriptor, &after) == 0, lstat(url.path, &pathAfter) == 0,
              same(before, after), same(before, pathAfter), count == before.st_size else {
            throw ExternalEditError.changed
        }
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }

    private static func same(_ a: stat, _ b: stat) -> Bool {
        a.st_dev == b.st_dev && a.st_ino == b.st_ino && a.st_size == b.st_size &&
        a.st_mtimespec.tv_sec == b.st_mtimespec.tv_sec && a.st_mtimespec.tv_nsec == b.st_mtimespec.tv_nsec &&
        a.st_ctimespec.tv_sec == b.st_ctimespec.tv_sec && a.st_ctimespec.tv_nsec == b.st_ctimespec.tv_nsec
    }
}
