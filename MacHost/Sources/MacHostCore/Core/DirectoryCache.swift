import Foundation

/// Двухуровневый кэш каталогов: L1 (In-Memory с TTL) для мгновенной навигации back/forward/tab switch
public final class DirectoryCache: @unchecked Sendable {
    public static let shared = DirectoryCache()
    
    private struct CacheEntry {
        let items: [FileItem]
        let timestamp: Date
    }
    
    private let lock = NSLock()
    private var memoryCache: [String: CacheEntry] = [:]
    public var ttlSeconds: TimeInterval = 5.0
    
    public init(ttlSeconds: TimeInterval = 5.0) {
        self.ttlSeconds = ttlSeconds
    }
    
    public func get(path: String) -> [FileItem]? {
        lock.lock()
        defer { lock.unlock() }
        let key = path.precomposedStringWithCanonicalMapping
        guard let entry = memoryCache[key] else { return nil }
        if Date().timeIntervalSince(entry.timestamp) > ttlSeconds {
            memoryCache.removeValue(forKey: key)
            return nil
        }
        return entry.items
    }
    
    public func set(path: String, items: [FileItem]) {
        lock.lock()
        defer { lock.unlock() }
        let key = path.precomposedStringWithCanonicalMapping
        memoryCache[key] = CacheEntry(items: items, timestamp: Date())
    }
    
    public func invalidate(path: String) {
        lock.lock()
        defer { lock.unlock() }
        let key = path.precomposedStringWithCanonicalMapping
        memoryCache.removeValue(forKey: key)
        let parent = (key as NSString).deletingLastPathComponent
        memoryCache.removeValue(forKey: parent)
    }
    
    public func invalidateAll() {
        lock.lock()
        defer { lock.unlock() }
        memoryCache.removeAll()
    }
}
