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
    
    private init() {
        let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        let dir = appSupport.appendingPathComponent("MacDroidCommander")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        self.storageURL = dir.appendingPathComponent("pinned_hosts.json")
        loadFromDisk()
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
        saveToDisk()
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
        return pinnedKeys[key] != nil
    }
    
    private func loadFromDisk() {
        guard let data = try? Data(contentsOf: storageURL),
              let dict = try? JSONDecoder().decode([String: String].self, from: data) else { return }
        self.pinnedKeys = dict
    }
    
    private func saveToDisk() {
        if let data = try? JSONEncoder().encode(pinnedKeys) {
            try? data.write(to: storageURL)
        }
    }
}
