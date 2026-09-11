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
    
    public func verifyOrPin(host: String, port: Int, fingerprint: String) -> HostKeyStatus {
        lock.lock()
        defer { lock.unlock() }
        
        let key = "\(host):\(port)"
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
    
    public func unpin(host: String, port: Int) {
        lock.lock()
        defer { lock.unlock() }
        pinnedKeys.removeValue(forKey: "\(host):\(port)")
        saveToDisk()
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
