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
    /// USB-серийники ADB, по которым это устройство уже подключалось (маршруты, не идентичность).
    /// Optional: файлы реестра без этого поля читаются как раньше.
    public var usbSerials: [String]?
    /// Явный выбор пользователя в окне сопряжения (true = значение autoConnect выбрано пользователем).
    /// Автоматические пути (первый подтверждённый ключ, однократная миграция) его не перезаписывают.
    /// Optional: файлы реестра без этого поля читаются как раньше (nil = выбора не было).
    public var autoConnectSetByUser: Bool?
    
    public init(
        id: String,
        name: String,
        pinnedFingerprint: String,
        lastKnownHost: String,
        lastKnownPort: UInt16 = 2222,
        lastSeenDate: Date = Date(),
        autoConnect: Bool = false,
        isMigratedToDedicatedKey: Bool = false,
        usbSerials: [String]? = nil,
        autoConnectSetByUser: Bool? = nil
    ) {
        self.id = id
        self.name = name
        self.pinnedFingerprint = pinnedFingerprint
        self.lastKnownHost = lastKnownHost
        self.lastKnownPort = lastKnownPort
        self.lastSeenDate = lastSeenDate
        self.autoConnect = autoConnect
        self.isMigratedToDedicatedKey = isMigratedToDedicatedKey
        self.usbSerials = usbSerials
        self.autoConnectSetByUser = autoConnectSetByUser
    }

    /// Маршрут через ADB forward (127.0.0.1) — не Wi-Fi адрес устройства.
    public static func isLoopbackHost(_ host: String) -> Bool {
        let norm = ConnectionHostAddress.normalized(host)
        return norm.hasPrefix("127.") || norm == "localhost" || norm == "::1"
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
        enableAutoConnectForPairedDevicesOnce()
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
    
    /// Запись по id; если её нет — запись с тем же закреплённым отпечатком (тот же телефон под другим id).
    public func device(withId id: String, orFingerprint fp: String) -> TrustedDevice? {
        lock.lock()
        defer { lock.unlock() }
        if let byId = devices[id] { return byId }
        guard !fp.isEmpty else { return nil }
        return devices.values.first(where: { $0.pinnedFingerprint == fp })
    }

    public func device(matchingFingerprint fp: String) -> TrustedDevice? {
        guard !fp.isEmpty else { return nil }
        lock.lock()
        defer { lock.unlock() }
        return devices.values.first(where: { $0.pinnedFingerprint == fp })
    }
    
    /// Устройство, которое подключалось по этому USB-серийнику (или было закреплено под ним).
    public func device(matchingUsbSerial serial: String) -> TrustedDevice? {
        guard !serial.isEmpty else { return nil }
        lock.lock()
        defer { lock.unlock() }
        if let byId = devices[serial] { return byId }
        return devices.values
            .filter { $0.usbSerials?.contains(serial) == true }
            .max(by: { $0.lastSeenDate < $1.lastSeenDate })
    }

    public func device(matchingHost host: String) -> TrustedDevice? {
        lock.lock()
        defer { lock.unlock() }
        let norm = ConnectionHostAddress.normalized(host)
        guard !norm.isEmpty else { return nil }
        return devices.values.first(where: { ConnectionHostAddress.normalized($0.lastKnownHost) == norm })
    }
    
    public func updateDeviceName(matchingHost host: String, name: String) {
        guard name != "Телефон Android" && name != "Android" && !name.isEmpty else { return }
        lock.lock()
        defer { lock.unlock() }
        let norm = ConnectionHostAddress.normalized(host)
        for (id, var dev) in devices {
            if ConnectionHostAddress.normalized(dev.lastKnownHost) == norm {
                if dev.name == "Телефон Android" || dev.name == "Android" || dev.name.isEmpty {
                    dev.name = name
                    devices[id] = dev
                    saveUnderLock()
                }
            }
        }
    }
    
    /// Регистрация или обновление устройства с сохранением идентичности при смене сетевого адреса
    public func registerOrUpdate(
        id: String,
        name: String,
        fingerprint: String,
        host: String,
        port: UInt16,
        autoConnect: Bool? = nil,
        isMigrated: Bool? = nil,
        usbSerial: String? = nil
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
            if name != "Телефон Android" && name != "Android" && !name.isEmpty {
                existing.name = name
            }
            // USB-подключение не затирает последний Wi-Fi маршрут: 127.0.0.1 — адрес ADB forward.
            if !Self.isLoopbackHostValue(host) || Self.isLoopbackHostValue(existing.lastKnownHost) || existing.lastKnownHost.isEmpty {
                existing.lastKnownHost = host
                existing.lastKnownPort = port
            }
            if let serial = usbSerial, !serial.isEmpty {
                var serials = existing.usbSerials ?? []
                if !serials.contains(serial) { serials.append(serial) }
                existing.usbSerials = serials
            }
            existing.lastSeenDate = Date()
            if let ac = autoConnect {
                existing.autoConnect = ac
            } else if existing.pinnedFingerprint.isEmpty && !fingerprint.isEmpty && existing.autoConnectSetByUser != true {
                // Запись без ключа (из старой истории) впервые получает подтверждённый ключ — это сопряжение.
                // Если пользователь уже выбрал настройку вручную, она не перезаписывается.
                existing.autoConnect = true
            }
            if !fingerprint.isEmpty {
                existing.pinnedFingerprint = fingerprint
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
                // Подтверждённое сопряжение (есть отпечаток) разрешает и автоподключение.
                autoConnect: autoConnect ?? !fingerprint.isEmpty,
                isMigratedToDedicatedKey: isMigrated ?? false,
                usbSerials: usbSerial.flatMap { $0.isEmpty ? nil : [$0] }
            )
            devices[effectiveId] = newDev
        }
        saveUnderLock()
    }
    
    private static func isLoopbackHostValue(_ host: String) -> Bool {
        TrustedDevice.isLoopbackHost(host)
    }

    /// Явный выбор пользователя (переключатель в окне сопряжения): запоминается и защищён от автоматической перезаписи.
    public func setAutoConnect(id: String, enabled: Bool) {
        lock.lock()
        defer { lock.unlock() }
        devices[id]?.autoConnect = enabled
        devices[id]?.autoConnectSetByUser = true
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
    
    /// Маркер однократного включения автоподключения лежит рядом с файлом реестра,
    /// чтобы тестовые реестры с собственным storageURL не зависели от настроек приложения.
    private var autoConnectMigrationMarkerURL: URL {
        storageURL.appendingPathExtension("autoconnect-v1")
    }

    /// Однократно: ранее сопряжённые устройства получают autoConnect = true.
    /// Повторно не выполняется, поэтому ручное выключение после миграции сохраняется.
    private func enableAutoConnectForPairedDevicesOnce() {
        lock.lock()
        defer { lock.unlock() }
        let marker = autoConnectMigrationMarkerURL
        guard !FileManager.default.fileExists(atPath: marker.path) else { return }
        var changed = false
        // Запись с явным выбором пользователя (в т.ч. «не подключаться») не трогается.
        for (id, var dev) in devices where !dev.pinnedFingerprint.isEmpty && !dev.autoConnect && dev.autoConnectSetByUser != true {
            dev.autoConnect = true
            devices[id] = dev
            changed = true
        }
        if changed { saveUnderLock() }
        FileManager.default.createFile(atPath: marker.path, contents: Data())
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
