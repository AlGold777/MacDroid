import AppKit
import Foundation

@MainActor
public final class ExternalEditManager: ObservableObject {
    @Published public private(set) var sessions: [ExternalEditSession] = []
    @Published public private(set) var messages: [UUID: String] = [:]
    @Published public private(set) var changed: Set<UUID> = []
    @Published public private(set) var busy: Set<UUID> = []
    @Published public private(set) var isRefreshing = false
    @Published public private(set) var errorMessage: String?
    private let store: ExternalEditStore
    private let transport: TransportMultiplexer
    private var opening: Set<String> = []
    private var uploadGeneration = 0

    public init(store: ExternalEditStore = ExternalEditStore(), transport: TransportMultiplexer = TransportMultiplexer()) {
        self.store = store
        self.transport = transport
    }

    public func refresh() async {
        guard !isRefreshing else { return }
        isRefreshing = true
        let generation = uploadGeneration
        defer { isRefreshing = false }
        do {
            let listed = try await store.list()
            guard generation == uploadGeneration else { return }
            sessions = listed
            errorMessage = nil
            for session in sessions where !busy.contains(session.id) {
                do {
                    let digest = try await store.currentDigest(session)
                    guard !busy.contains(session.id), generation == uploadGeneration else { continue }
                    if digest != session.savedDigest {
                        changed.insert(session.id)
                        messages[session.id] = "Есть изменения — можно сохранить копию на телефон"
                    } else {
                        changed.remove(session.id)
                        messages[session.id] = session.lastSavedPath == nil
                            ? "Без изменений" : "Совпадает с последней сохранённой копией"
                    }
                } catch {
                    guard !busy.contains(session.id), generation == uploadGeneration else { continue }
                    changed.remove(session.id)
                    messages[session.id] = "Рабочая копия недоступна: \(error.localizedDescription)"
                }
            }
        } catch { errorMessage = error.localizedDescription }
    }

    public func prepare(_ item: FileItem) async throws -> URL {
        guard !item.isDirectory, !item.isSymbolicLink else { throw ExternalEditError.invalidName }
        try await transport.ensureConnected()
        guard let fingerprint = transport.coordinator.hostKeyFingerprint,
              HostKeyStore.shared.pinnedDeviceId(matchingFingerprint: fingerprint) != nil else {
            throw ExternalEditError.wrongDevice
        }
        let epoch = transport.coordinator.sessionEpoch
        let key = fingerprint + "\n" + item.path
        guard opening.insert(key).inserted else {
            throw NSError(domain: "ExternalEdit", code: 1, userInfo: [NSLocalizedDescriptionKey: "Этот файл уже скачивается для открытия"])
        }
        defer { opening.remove(key) }
        if let existing = try await store.existing(deviceFingerprint: fingerprint, remotePath: item.path) {
            _ = try await store.currentDigest(existing)
            return await store.workingURL(existing)
        }
        let (id, localURL) = try await store.allocate(fileName: item.name)
        let before = try await transport.prepareRead(actionId: id.uuidString, path: item.path)
        guard !before.isDirectory else { throw ExternalEditError.invalidName }
        try await transport.downloadFileStreaming(actionId: id.uuidString, remotePath: item.path,
                                                   targetURL: localURL, totalSize: before.size) { _ in }
        let remoteDigest = try await transport.digestRemoteFile(at: item.path, expectedSize: before.size,
                                                               expectedMtime: Double(before.mtime))
        let localDigest = try await store.digestFile(localURL)
        guard transport.coordinator.sessionEpoch == epoch,
              transport.coordinator.hostKeyFingerprint == fingerprint else { throw ExternalEditError.wrongDevice }
        guard localDigest == remoteDigest else { throw ExternalEditError.changed }
        _ = try await store.register(id: id, fileName: item.name, remotePath: item.path, deviceFingerprint: fingerprint)
        await refresh()
        return localURL
    }

    public func open(_ session: ExternalEditSession) async {
        let url = await store.workingURL(session)
        if !NSWorkspace.shared.open(url) { messages[session.id] = "Не удалось открыть рабочую копию" }
    }

    public func reveal(_ session: ExternalEditSession) async {
        NSWorkspace.shared.activateFileViewerSelecting([await store.workingURL(session)])
    }

    public func saveCopy(_ session: ExternalEditSession) async {
        guard busy.insert(session.id).inserted else { return }
        uploadGeneration += 1
        defer {
            uploadGeneration += 1
            busy.remove(session.id)
        }
        messages[session.id] = "Подготовка и отправка копии…"
        do {
            try await transport.ensureConnected()
            guard transport.coordinator.hostKeyFingerprint == session.deviceFingerprint else {
                throw ExternalEditError.wrongDevice
            }
            let snapshot = try await store.snapshot(session.id)
            try await store.beginUpload(session.id, remotePath: snapshot.remotePath)
            sessions = try await store.list()
            try await transport.publishEditedCopy(snapshot: snapshot, deviceFingerprint: session.deviceFingerprint)
            try await store.completeUpload(session.id, snapshot: snapshot)
            sessions = try await store.list()
            // Publishing is confirmed even if the editor temporarily removes the working file afterwards.
            do {
                let current = try await store.currentDigest(session)
                if current != snapshot.digest {
                    changed.insert(session.id)
                    messages[session.id] = "Копия сохранена; в редакторе уже есть новые изменения"
                } else {
                    changed.remove(session.id)
                    messages[session.id] = "Копия сохранена и проверена на телефоне"
                }
            } catch {
                changed.remove(session.id)
                messages[session.id] = "Копия сохранена на телефоне; рабочая копия сейчас недоступна: \(error.localizedDescription)"
            }
        } catch {
            messages[session.id] = "Сохранение не подтверждено: \(error.localizedDescription)"
            do { sessions = try await store.list() } catch { errorMessage = error.localizedDescription }
        }
    }
}
