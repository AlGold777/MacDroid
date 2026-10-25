import Foundation

/// Pins cleanup to the live SFTP session that produced the preview.
public struct CopyDoneSession: Sendable {
    public let service: CopyDoneService
    public let locations: [CopyDoneLocation]
    private let storage: CopyDoneTrashStorage

    public init(remote: RemoteSFTPDriver, transport: TransportMultiplexer, deviceID: String?) throws {
        let coordinator = remote.coordinator
        guard coordinator.isConnected, let channel = coordinator.interactiveChannel else {
            throw Self.failure("Подключите телефон для проверки копий.")
        }
        let epoch = coordinator.sessionEpoch
        let host = coordinator.host, port = coordinator.port
        let sessionDevice = coordinator.deviceId
        let fingerprint = coordinator.hostKeyFingerprint
        let validate: CopyDoneService.Validate = {
            guard coordinator.isConnected, coordinator.sessionEpoch == epoch,
                  coordinator.interactiveChannel === channel,
                  coordinator.host == host, coordinator.port == port,
                  coordinator.deviceId == sessionDevice, coordinator.hostKeyFingerprint == fingerprint else {
                throw Self.failure("Подключение телефона изменилось. Повторите проверку копий.")
            }
        }
        let content = FileContentService(transport: transport)
        service = CopyDoneService(metadata: { path, source in
            try validate()
            if source == .localMac { return try CopyDoneService.localMetadata(path) }
            let parent = (path as NSString).deletingLastPathComponent
            let items = try await remote.listDirectory(at: parent, forceRefresh: true)
            try validate()
            guard let item = items.first(where: { CopyDoneService.phonePath($0.path) == CopyDoneService.phonePath(path) }) else {
                throw Self.failure("Файл телефона не найден: \(path)")
            }
            return item
        }, contentDigest: { item in
            try validate()
            let result = try await content.digest(item)
            try validate()
            return result
        }, validateSession: validate)
        let identity = "\(deviceID ?? "phone"):\(host):\(port)"
        locations = TransferJournal.shared.copyDoneLocations(deviceID: deviceID, sessionIdentity: identity)
        storage = CopyDoneTrashStorage(remote: remote, validate: validate)
    }

    public func moveToTrash(_ item: FileItem, beforeMove: @escaping CopyDoneService.BeforeMove) async throws -> PhoneTrashEntry {
        try storage.validate()
        return try await PhoneTrashService(storage: storage).moveToTrash(at: item.path, beforeMove: beforeMove)
    }

    public func restore(_ entry: PhoneTrashEntry) async throws {
        try storage.validate()
        try await PhoneTrashService(storage: storage).restore(entry)
    }

    private static func failure(_ message: String) -> NSError {
        NSError(domain: "CopyDoneSession", code: 1, userInfo: [NSLocalizedDescriptionKey: message])
    }
}

/// Check every step of a multi-request trash operation, including recovery.
private struct CopyDoneTrashStorage: PhoneTrashStorage {
    let remote: RemoteSFTPDriver
    let validate: CopyDoneService.Validate

    func list(_ path: String) async throws -> [FileItem] {
        try validate()
        let result = try await remote.list(path)
        try validate()
        return result
    }
    func exists(_ path: String) async throws -> Bool {
        try validate()
        let result = try await remote.exists(path)
        try validate()
        return result
    }
    func mkdir(_ path: String) async throws {
        try validate(); try await remote.mkdir(path); try validate()
    }
    func rename(_ source: String, _ destination: String) async throws {
        try validate(); try await remote.rename(source, destination); try validate()
    }
    func readSmallFile(_ path: String, maxBytes: Int) async throws -> Data {
        try validate()
        let result = try await remote.readSmallFile(path, maxBytes: maxBytes)
        try validate()
        return result
    }
    func writeExclusive(_ path: String, data: Data) async throws {
        try validate(); try await remote.writeExclusive(path, data: data); try validate()
    }
    func deleteFile(_ path: String) async throws {
        try validate(); try await remote.deleteFile(path); try validate()
    }
    func deletePermanent(_ path: String) async throws {
        // Copy-done never permanently removes a payload.
        throw NSError(domain: "CopyDoneSession", code: 2, userInfo: [NSLocalizedDescriptionKey: "Безвозвратное удаление здесь запрещено."])
    }
    func removeEmptyDirectory(_ path: String) async throws {
        try validate(); try await remote.removeEmptyDirectory(path); try validate()
    }
}
