import Foundation

public enum HostKeyStatus: Sendable {
    case trusted
    case pinnedNew
    case mismatchWarning(expected: String, actual: String)
}

public final class HostKeyStore: @unchecked Sendable {
    public static let shared = HostKeyStore()
    private let lock = NSLock()
    private var pinnedKeys: [String: String] = [:] // host:port -> fingerprint
    private let storageURL: URL

    public static func safeHostKeyAlias(_ value: String) -> String {
        let safe = String(value.map { $0.isLetter || $0.isNumber || $0 == "-" || $0 == "_" ? $0 : "_" })
        return safe.isEmpty ? "device" : safe
    }
    
    private init() {
        let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        let dir = appSupport.appendingPathComponent("MacDroidCommander")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        self.storageURL = dir.appendingPathComponent("pinned_hosts.json")
        loadFromDisk()
    }
    
    /// Распознавание устаревших фиктивных отпечатков из ранних тестовых сборок
    public static func isLegacyMockFingerprint(_ fp: String) -> Bool {
        return fp.contains("Xiaomi14Ultra_DaemonFingerprint")
    }
    
    public func verifyOrPin(host: String, port: Int, deviceId: String? = nil, fingerprint: String) -> HostKeyStatus {
        lock.lock()
        defer { lock.unlock() }
        
        let effectiveDeviceId = deviceId ?? PhoneConnectionManager.shared.getConnectedDeviceId()
        let key: String
        if (host == "127.0.0.1" || host == "localhost"), let dev = effectiveDeviceId, !dev.isEmpty {
            key = "usb_\(dev)"
        } else {
            key = "\(host):\(port)"
        }
        
        if let existing = pinnedKeys[key] {
            if Self.isLegacyMockFingerprint(existing) {
                // Если старый сохраненный ключ был устаревшим моком из ранних версий, автомигрируем на реальный
                pinnedKeys[key] = fingerprint
                saveToDisk()
                return .pinnedNew
            }
            if existing == fingerprint {
                return .trusted
            } else {
                return .mismatchWarning(expected: existing, actual: fingerprint)
            }
        } else {
            pinnedKeys[key] = fingerprint
            saveToDisk()
            return .pinnedNew
        }
    }

    public func openSSHKnownHostsURL(host: String, port: UInt16, deviceId: String? = nil) -> URL {
        let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        return appSupport.appendingPathComponent("MacDroidCommander", isDirectory: true).appendingPathComponent("known_hosts")
    }

    /// Обновляет SSH known_hosts только после успешной проверки отпечатка в HostKeyStore.
    public func installOpenSSHHostKey(_ observation: SSHHostKeyObservation, host: String, port: UInt16, deviceId: String? = nil, hostKeyAlias: String? = nil) throws {
        lock.lock()
        defer { lock.unlock() }

        let observedFields = observation.knownHostsLine.split(whereSeparator: \.isWhitespace)
        guard observedFields.count >= 3 else {
            throw NSError(domain: "HostKeyStore", code: 1, userInfo: [NSLocalizedDescriptionKey: "Некорректная строка ключа SSH."])
        }
        let alias = hostKeyAlias ?? "mcd-" + String(observation.fingerprint.filter { $0.isLetter || $0.isNumber }.suffix(24))
        let knownHostsHost = "[\(alias)]:\(port)"
        let knownHostsLine = ([knownHostsHost] + observedFields.dropFirst().map(String.init)).joined(separator: " ")

        let url = openSSHKnownHostsURL(host: host, port: port, deviceId: deviceId)
        let directory = url.deletingLastPathComponent()
        try FileManager.default.createDirectory(
            at: directory,
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700]
        )
        let existingLines = (try? String(contentsOf: url, encoding: .utf8))?
            .split(whereSeparator: \.isNewline)
            .map(String.init) ?? []
        let preservedLines = existingLines.filter { line in
            guard let lineHost = line.split(whereSeparator: \.isWhitespace).first else { return false }
            return lineHost != knownHostsHost
        }
        let updatedContents = (preservedLines + [knownHostsLine]).joined(separator: "\n") + "\n"
        try Data(updatedContents.utf8).write(to: url, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
    }
    
    public func unpin(host: String, port: Int, deviceId: String? = nil) {
        lock.lock()
        defer { lock.unlock() }
        let effectiveDeviceId = deviceId ?? PhoneConnectionManager.shared.getConnectedDeviceId()
        let key: String
        if (host == "127.0.0.1" || host == "localhost"), let dev = effectiveDeviceId, !dev.isEmpty {
            key = "usb_\(dev)"
        } else {
            key = "\(host):\(port)"
        }
        pinnedKeys.removeValue(forKey: key)
        if host == "127.0.0.1" || host == "localhost" {
            pinnedKeys.removeValue(forKey: "\(host):\(port)")
            if let dev = effectiveDeviceId, !dev.isEmpty {
                pinnedKeys.removeValue(forKey: "usb_\(dev)")
            }
        }
        saveToDisk()
    }
    
    public func resetHostKey(host: String, port: Int, deviceId: String? = nil) {
        unpin(host: host, port: port, deviceId: deviceId)
    }
    
    public func isHostPinned(host: String, port: Int, deviceId: String? = nil) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        let effectiveDeviceId = deviceId ?? PhoneConnectionManager.shared.getConnectedDeviceId()
        let key: String
        if (host == "127.0.0.1" || host == "localhost"), let dev = effectiveDeviceId, !dev.isEmpty {
            key = "usb_\(dev)"
        } else {
            key = "\(host):\(port)"
        }
        guard let existing = pinnedKeys[key] else { return false }
        return !Self.isLegacyMockFingerprint(existing)
    }
    
    private func loadFromDisk() {
        guard let data = try? Data(contentsOf: storageURL),
              let dict = try? JSONDecoder().decode([String: String].self, from: data) else { return }
        self.pinnedKeys = dict
        
        // Автоматическая очистка устаревших фиктивных отпечатков из ранних версий
        var modified = false
        for (k, v) in self.pinnedKeys {
            if Self.isLegacyMockFingerprint(v) {
                self.pinnedKeys.removeValue(forKey: k)
                modified = true
            }
        }
        if modified {
            saveToDisk()
        }
    }
    
    private func saveToDisk() {
        if let data = try? JSONEncoder().encode(pinnedKeys) {
            try? data.write(to: storageURL)
        }
    }
}
