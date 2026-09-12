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

/// Реестр доверенных устройств MacDroid Commander
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
    
    public func device(matchingHost host: String) -> TrustedDevice? {
        lock.lock()
        defer { lock.unlock() }
        return devices.values.first(where: { $0.lastKnownHost == host })
    }
    
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
        defer {
            lock.unlock()
            save()
        }
        
        if var existing = devices[id] {
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
            devices[id] = existing
        } else {
            let newDev = TrustedDevice(
                id: id,
                name: name,
                pinnedFingerprint: fingerprint,
                lastKnownHost: host,
                lastKnownPort: port,
                lastSeenDate: Date(),
                autoConnect: autoConnect ?? false,
                isMigratedToDedicatedKey: isMigrated ?? false
            )
            devices[id] = newDev
        }
    }
    
    public func setAutoConnect(id: String, enabled: Bool) {
        lock.lock()
        defer {
            lock.unlock()
            save()
        }
        devices[id]?.autoConnect = enabled
    }
    
    public func setMigrated(id: String, migrated: Bool) {
        lock.lock()
        defer {
            lock.unlock()
            save()
        }
        devices[id]?.isMigratedToDedicatedKey = migrated
    }
    
    public func remove(id: String) {
        lock.lock()
        defer {
            lock.unlock()
            save()
        }
        devices.removeValue(forKey: id)
    }
    
    // MARK: - Persistence
    
    private func save() {
        let list = Array(devices.values)
        if let data = try? JSONEncoder().encode(list) {
            try? data.write(to: storageURL, options: .atomic)
        }
    }
    
    private func load() {
        guard FileManager.default.fileExists(atPath: storageURL.path),
              let data = try? Data(contentsOf: storageURL),
              let list = try? JSONDecoder().decode([TrustedDevice].self, from: data) else {
            return
        }
        devices.removeAll()
        for item in list {
            devices[item.id] = item
        }
    }
    
    private func migrateLegacyDataIfNeeded() {
        if !devices.isEmpty { return }
        
        // Миграция из UserDefaults phoneConnectionHistory
        if let data = UserDefaults.standard.data(forKey: "phoneConnectionHistory"),
           let legacyList = try? JSONDecoder().decode([SavedConnection].self, from: data) {
            for item in legacyList {
                let id = "legacy_\(item.host)_\(item.port)"
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
            save()
        }
    }
}
