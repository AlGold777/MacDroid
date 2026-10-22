import Foundation

/// Описание доверенного устройства (слой идентичности и доверия)
public struct TrustedDevice: Codable, Identifiable, Sendable, Equatable {
    public let id: String
    public var name: String
    public var pinnedFingerprint: String
    public var lastKnownHost: String
    public var lastKnownPort: UInt16
    public var lastSeenDate: Date
    public var autoConnect: Bool
    public var isMigratedToDedicatedKey: Bool
    
    public init(
        id: String,
        name: String,
        pinnedFingerprint: String,
        lastKnownHost: String,
        lastKnownPort: UInt16 = 2222,
        lastSeenDate: Date = Date(),
        autoConnect: Bool = false,
        isMigratedToDedicatedKey: Bool = false
    ) {
        self.id = id
        self.name = name
        self.pinnedFingerprint = pinnedFingerprint
        self.lastKnownHost = lastKnownHost
        self.lastKnownPort = lastKnownPort
        self.lastSeenDate = lastSeenDate
        self.autoConnect = autoConnect
        self.isMigratedToDedicatedKey = isMigratedToDedicatedKey
    }
}

/// Реестр доверенных устройств MacDroid Commander (потокобезопасный синглтон)
public final class DeviceRegistry: @unchecked Sendable {
    public static let shared = DeviceRegistry()
    
    private let lock = NSLock()
    private var devices: [String: TrustedDevice] = [:]
    private let storageURL: URL
    
    public init(storageURL: URL? = nil) {
        if let customURL = storageURL {
            self.storageURL = customURL
        } else {
            let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
            let dir = appSupport.appendingPathComponent("MacDroidCommander", isDirectory: true)
            try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            self.storageURL = dir.appendingPathComponent("trusted_devices.json")
        }
        load()
        migrateLegacyDataIfNeeded()
    }
    
    public func allDevices() -> [TrustedDevice] {
        lock.lock()
        defer { lock.unlock() }
        return Array(devices.values).sorted(by: { $0.lastSeenDate > $1.lastSeenDate })
    }
    
    public func device(withId id: String) -> TrustedDevice? {
        lock.lock()
        defer { lock.unlock() }
        return devices[id]
    }
    
    public func device(matchingFingerprint fp: String) -> TrustedDevice? {
        guard !fp.isEmpty else { return nil }
        lock.lock()
        defer { lock.unlock() }
        return devices.values.first(where: { $0.pinnedFingerprint == fp })
    }
    
    public func device(matchingHost host: String) -> TrustedDevice? {
        lock.lock()
        defer { lock.unlock() }
        return devices.values.first(where: { $0.lastKnownHost == host })
    }
    
    /// Регистрация или обновление устройства с сохранением идентичности при смене сетевого адреса
    public func registerOrUpdate(
        id: String,
        name: String,
        fingerprint: String,
        host: String,
        port: UInt16,
        autoConnect: Bool? = nil,
        isMigrated: Bool? = nil
    ) {
        lock.lock()
        defer { lock.unlock() }
        
        // Поиск существующего устройства сначала по стабильному отпечатку ключа, затем по id
        let effectiveId: String
        if !fingerprint.isEmpty, let byFp = devices.values.first(where: { $0.pinnedFingerprint == fingerprint }) {
            effectiveId = byFp.id
        } else {
            effectiveId = id
        }
        
        if var existing = devices[effectiveId] {
            existing.name = name
            existing.lastKnownHost = host
            existing.lastKnownPort = port
            existing.lastSeenDate = Date()
            if !fingerprint.isEmpty {
                existing.pinnedFingerprint = fingerprint
            }
            if let ac = autoConnect {
                existing.autoConnect = ac
            }
            if let mig = isMigrated {
                existing.isMigratedToDedicatedKey = mig
            }
            devices[effectiveId] = existing
        } else {
            let newDev = TrustedDevice(
                id: effectiveId,
                name: name,
                pinnedFingerprint: fingerprint,
                lastKnownHost: host,
                lastKnownPort: port,
                lastSeenDate: Date(),
                autoConnect: autoConnect ?? false,
                isMigratedToDedicatedKey: isMigrated ?? false
            )
            devices[effectiveId] = newDev
        }
        saveUnderLock()
    }
    
    public func setAutoConnect(id: String, enabled: Bool) {
        lock.lock()
        defer { lock.unlock() }
        devices[id]?.autoConnect = enabled
        saveUnderLock()
    }
    
    public func setMigrated(id: String, migrated: Bool) {
        lock.lock()
        defer { lock.unlock() }
        devices[id]?.isMigratedToDedicatedKey = migrated
        saveUnderLock()
    }
    
    public func remove(id: String) {
        lock.lock()
        defer { lock.unlock() }
        devices.removeValue(forKey: id)
        saveUnderLock()
    }
    
    // MARK: - Persistence (выполняется строго внутри захваченного lock)
    
    private func saveUnderLock() {
        let list = Array(devices.values)
        do {
            let data = try JSONEncoder().encode(list)
            try data.write(to: storageURL, options: .atomic)
            // Реестр доверенных устройств доступен только владельцу (как и pinned_hosts.json).
            try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: storageURL.path)
        } catch {
            print("[DeviceRegistry] Failed to save trusted devices: \(error)")
        }
    }
    
    private func load() {
        guard FileManager.default.fileExists(atPath: storageURL.path),
              let data = try? Data(contentsOf: storageURL),
              let list = try? JSONDecoder().decode([TrustedDevice].self, from: data) else {
            return
        }
        lock.lock()
        defer { lock.unlock() }
        devices.removeAll()
        for item in list {
            devices[item.id] = item
        }
    }
    
    private func migrateLegacyDataIfNeeded() {
        lock.lock()
        defer { lock.unlock() }
        if !devices.isEmpty { return }
        
        // Миграция из UserDefaults phoneConnectionHistory
        if let data = UserDefaults.standard.data(forKey: "phoneConnectionHistory"),
           let legacyList = try? JSONDecoder().decode([SavedConnection].self, from: data) {
            for item in legacyList {
                let id = "device_\(item.host)"
                let dev = TrustedDevice(
                    id: id,
                    name: item.name,
                    pinnedFingerprint: "",
                    lastKnownHost: item.host,
                    lastKnownPort: UInt16(item.port),
                    lastSeenDate: item.date,
                    autoConnect: false,
                    isMigratedToDedicatedKey: false
                )
                devices[id] = dev
            }
            saveUnderLock()
        }
    }
}
