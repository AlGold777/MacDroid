import Foundation

public struct CopyDoneScope: Sendable, Hashable {
    public let path: String
    public let isDirectory: Bool

    public init(path: String, isDirectory: Bool) {
        self.path = path
        self.isDirectory = isDirectory
    }

    public func contains(_ phonePath: String) -> Bool {
        let root = CopyDoneService.phonePath(path)
        let candidate = CopyDoneService.phonePath(phonePath)
        return candidate == root || (isDirectory && candidate.hasPrefix(root == "/" ? root : root + "/"))
    }
}

/// A location from the transfer journal is a hint, never evidence that a copy exists.
public struct CopyDoneLocation: Sendable, Hashable {
    public let phonePath: String
    public let macPath: String

    public init(phonePath: String, macPath: String) {
        self.phonePath = phonePath
        self.macPath = macPath
    }
}

public struct CopyDoneEntry: Identifiable, Sendable {
    public var id: String { CopyDoneService.phonePath(phone.path) }
    public let phone: FileItem
    public let macCopies: [FileItem]
    public let digest: String

    public init(phone: FileItem, macCopies: [FileItem], digest: String) {
        self.phone = phone
        self.macCopies = macCopies
        self.digest = digest
    }
}

public struct CopyDoneScan: Sendable {
    public let entries: [CopyDoneEntry]
    public let issues: [String]
    public let candidateCount: Int
}

public struct CopyDoneCleanupError: LocalizedError, Sendable {
    public let completedIDs: [String]
    public let detail: String
    public var errorDescription: String? { detail }
}

/// All content reads are fresh; no historical hash or completed state authorizes removal.
public struct CopyDoneService: Sendable {
    public typealias Metadata = @Sendable (String, FileSource) async throws -> FileItem
    public typealias Digest = @Sendable (FileItem) async throws -> String
    public typealias Validate = @Sendable () throws -> Void
    public typealias BeforeMove = @Sendable () async throws -> Void
    public typealias Move = @Sendable (FileItem, @escaping BeforeMove) async throws -> PhoneTrashEntry

    private let metadata: Metadata
    private let digest: Digest
    private let validateSession: Validate

    public init(metadata: @escaping Metadata, contentDigest: @escaping Digest,
                validateSession: @escaping Validate = {}) {
        self.metadata = metadata
        self.digest = contentDigest
        self.validateSession = validateSession
    }

    public static func phonePath(_ path: String) -> String {
        let normalized = (path as NSString).standardizingPath.precomposedStringWithCanonicalMapping
        for alias in ["/sdcard", "/emulated/0", "/storage/self/primary", "/mnt/sdcard"] {
            if normalized == alias || normalized.hasPrefix(alias + "/") {
                return "/storage/emulated/0" + normalized.dropFirst(alias.count)
            }
        }
        return normalized
    }

    public static func localMetadata(_ path: String) throws -> FileItem {
        let url = URL(fileURLWithPath: path)
        let values = try url.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey,
                                                     .fileSizeKey, .contentModificationDateKey])
        let resolved = url.resolvingSymlinksInPath().path
        guard values.isRegularFile == true, values.isSymbolicLink != true,
              !resolved.split(separator: "/").contains(where: { [".Trash", ".Trashes", PhoneTrashService.directoryName].contains(String($0)) }),
              let size = values.fileSize, size >= 0, let date = values.contentModificationDate else {
            throw failure("Копия недоступна или находится в корзине: \(path)")
        }
        return FileItem(id: path, name: url.lastPathComponent, path: path, size: UInt64(size),
                        mtime: date.timeIntervalSince1970, isDirectory: false, source: .localMac)
    }

    public func findCopies(locations: [CopyDoneLocation], scopes: [CopyDoneScope],
                           progress: @Sendable (Int, Int, String) -> Void = { _, _, _ in }) async throws -> CopyDoneScan {
        try check()
        let relevant = Set(locations.filter { location in
            scopes.contains { $0.contains(location.phonePath) }
                && !Self.phonePath(location.phonePath).split(separator: "/").contains(Substring(PhoneTrashService.directoryName))
        })
        let grouped = Dictionary(grouping: relevant, by: { Self.phonePath($0.phonePath) })
        var entries: [CopyDoneEntry] = []
        var issues: [String] = []
        for (index, path) in grouped.keys.sorted().enumerated() {
            try check()
            progress(index, grouped.count, path)
            do {
                let phone = try await metadata(path, .remotePhone)
                try validateItem(phone, source: .remotePhone)
                var candidates: [(FileItem, String)] = []
                let macPaths = Set((grouped[path] ?? []).map(\.macPath))
                for macPath in macPaths.sorted() {
                    try check()
                    do {
                        let mac = try await metadata(macPath, .localMac)
                        try validateItem(mac, source: .localMac)
                        guard mac.size == phone.size else { throw Self.failure("Размер копии изменился: \(mac.path)") }
                        candidates.append((mac, try await digest(mac)))
                    } catch is CancellationError { throw CancellationError() }
                    catch { issues.append(error.localizedDescription) }
                }
                if !candidates.isEmpty {
                    let phoneDigest = try await digest(phone)
                    try check()
                    let copies = candidates.compactMap { mac, hash -> FileItem? in
                        guard hash == phoneDigest else {
                            issues.append("Содержимое копии не совпадает: \(mac.path)")
                            return nil
                        }
                        return mac
                    }
                    if !copies.isEmpty { entries.append(CopyDoneEntry(phone: phone, macCopies: copies, digest: phoneDigest)) }
                }
            } catch is CancellationError { throw CancellationError() }
            catch { issues.append("\(path): \(error.localizedDescription)") }
            try check()
            progress(index + 1, grouped.count, path)
        }
        try check()
        return CopyDoneScan(entries: entries, issues: issues, candidateCount: grouped.count)
    }

    public func moveSelected(entries: [CopyDoneEntry], selectedIDs: Set<String>,
                             moveToTrash: @escaping Move,
                             restore: @escaping @Sendable (PhoneTrashEntry) async throws -> Void,
                             progress: @Sendable (Int, Int, String) -> Void = { _, _, _ in }) async throws -> [String] {
        var completed: [String] = []
        do {
            let known = Set(entries.map(\.id))
            guard known.count == entries.count, selectedIDs.isSubset(of: known) else {
                throw Self.failure("Результаты устарели. Повторите проверку.")
            }
            for entry in entries where selectedIDs.contains(entry.id) {
                try check()
                try validateItem(entry.phone, source: .remotePhone)
                guard !entry.macCopies.isEmpty else { throw Self.failure("Нет копии на Mac: \(entry.phone.path)") }
                progress(completed.count, selectedIDs.count, entry.phone.path)
                // PhoneTrashService invokes this after preparing metadata, immediately before RENAME.
                let trashed = try await moveToTrash(entry.phone) {
                    try check()
                    try await verifyMacCopy(entry)
                    guard try await digest(entry.phone) == entry.digest else {
                        throw Self.failure("Файл телефона изменился: \(entry.phone.path)")
                    }
                    try check()
                }
                do {
                    try check()
                    let payloadPath = try trashed.entryPath + "/" + PhoneTrashService.payloadName
                    let payload = try await metadata(payloadPath, .remotePhone)
                    guard !payload.isDirectory, !payload.isSymbolicLink, payload.source == .remotePhone,
                          payload.size == entry.phone.size, payload.mtime == entry.phone.mtime,
                          try await digest(payload) == entry.digest else {
                        throw Self.failure("Файл изменился во время переноса: \(entry.phone.path)")
                    }
                    try await verifyMacCopy(entry)
                    try check()
                } catch {
                    let reason = error.localizedDescription
                    // Recovery must run even if the user's task has been cancelled, but never on another session.
                    do {
                        try await Task.detached {
                            try validateSession()
                            try await restore(trashed)
                        }.value
                    } catch {
                        let payloadPath = (try? trashed.entryPath) ?? trashed.id
                        throw Self.failure("\(reason) Восстановление не завершено: \(error.localizedDescription). Файл сохранён в корзине: \(payloadPath). Восстановите его через «Корзина телефона…».")
                    }
                    throw Self.failure("\(reason) Файл возвращён на исходное место.")
                }
                completed.append(entry.id)
                progress(completed.count, selectedIDs.count, entry.phone.path)
            }
            return completed
        } catch {
            let reason = error is CancellationError ? "Операция остановлена." : error.localizedDescription
            throw CopyDoneCleanupError(completedIDs: completed, detail: reason)
        }
    }

    private func verifyMacCopy(_ entry: CopyDoneEntry) async throws {
        for mac in entry.macCopies {
            try check()
            do {
                try validateItem(mac, source: .localMac)
                let current = try await metadata(mac.path, .localMac)
                try validateItem(current, source: .localMac)
                guard current.size == mac.size, current.mtime == mac.mtime else { continue }
                if try await digest(mac) == entry.digest { try check(); return }
            } catch is CancellationError { throw CancellationError() }
            catch { try check() }
        }
        throw Self.failure("Проверенные копии на Mac удалены, изменены или недоступны: \(entry.phone.path). Повторите проверку.")
    }

    private func validateItem(_ item: FileItem, source: FileSource) throws {
        guard item.source == source, !item.isDirectory, !item.isSymbolicLink,
              !item.path.split(separator: "/").contains(Substring(PhoneTrashService.directoryName)) else {
            throw Self.failure("Нельзя использовать этот объект: \(item.path)")
        }
    }

    private func check() throws {
        try Task.checkCancellation()
        try validateSession()
    }

    private static func failure(_ message: String) -> NSError {
        NSError(domain: "CopyDone", code: 1, userInfo: [NSLocalizedDescriptionKey: message])
    }
}
