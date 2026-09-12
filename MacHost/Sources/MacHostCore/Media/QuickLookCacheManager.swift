import Foundation
import CryptoKit

public final class QuickLookCacheManager: @unchecked Sendable {
    public static let shared = QuickLookCacheManager()
    
    private let fileManager = FileManager.default
    public let cacheDir: URL
    public var maxDiskBytes: UInt64 = 1024 * 1024 * 1024 // 1 GB LRU Limit
    
    private var inFlightTasks: [URL: Task<URL, Error>] = [:]
    private let lock = NSLock()
    
    public init(customCacheDir: URL? = nil) {
        if let customDir = customCacheDir {
            self.cacheDir = customDir
        } else {
            let paths = fileManager.urls(for: .cachesDirectory, in: .userDomainMask)
            self.cacheDir = paths[0].appendingPathComponent("com.macandroid.filemanager.quicklook")
        }
        try? fileManager.createDirectory(at: self.cacheDir, withIntermediateDirectories: true)
    }
    
    public func cacheURL(for item: FileItem) -> URL {
        let ext = URL(fileURLWithPath: item.name).pathExtension
        let baseName = URL(fileURLWithPath: item.name).deletingPathExtension().lastPathComponent
        // Оптимизация P2: Включаем deviceId, path, size и mtime в ключ кэша.
        // Это предотвращает коллизии разных телефонов и возврат устаревших данных при изменении файла
        let deviceId = PhoneConnectionManager.shared.getConnectedDeviceId() ?? "phone"
        let keyData = Data("\(deviceId):\(item.path):\(item.size):\(Int64(item.mtime))".utf8)
        let pathHash = SHA256.hash(data: keyData)
            .prefix(8).map { String(format: "%02x", $0) }.joined()
        let safeBase = baseName.addingPercentEncoding(withAllowedCharacters: .alphanumerics) ?? "preview"
        
        let filename: String
        if ext.isEmpty {
            filename = "\(safeBase)_\(pathHash)_\(item.size)_\(Int64(item.mtime))"
        } else {
            filename = "\(safeBase)_\(pathHash)_\(item.size)_\(Int64(item.mtime)).\(ext)"
        }
        return cacheDir.appendingPathComponent(filename)
    }
    
    public func isCached(for item: FileItem) -> URL? {
        let targetURL = cacheURL(for: item)
        guard fileManager.fileExists(atPath: targetURL.path) else { return nil }
        
        if let attrs = try? fileManager.attributesOfItem(atPath: targetURL.path),
           let fileSize = attrs[.size] as? UInt64,
           fileSize == item.size {
            // Обновляем дату доступа для LRU
            try? fileManager.setAttributes([.modificationDate: Date()], ofItemAtPath: targetURL.path)
            return targetURL
        }
        return nil
    }
    
    public func fetchFile(
        item: FileItem,
        downloader: @escaping @Sendable (String, URL, UInt64, (@Sendable (Double) -> Void)?) async throws -> Void,
        onProgress: (@Sendable (Double) -> Void)? = nil
    ) async throws -> URL {
        if let existing = isCached(for: item) {
            onProgress?(1.0)
            return existing
        }
        
        let targetURL = cacheURL(for: item)
        
        // Оптимизация P2: Дедупликация конкурентных запросов одного и того же файла
        lock.lock()
        if let existingTask = inFlightTasks[targetURL] {
            lock.unlock()
            return try await existingTask.value
        }
        
        let task = Task<URL, Error> { [weak self] () -> URL in
            guard let self = self else { throw CancellationError() }
            let partURL = targetURL.appendingPathExtension("part")
            try? self.fileManager.removeItem(at: partURL)
            try? self.fileManager.removeItem(at: targetURL)
            
            do {
                try await downloader(item.path, partURL, item.size, onProgress)
                try self.fileManager.moveItem(at: partURL, to: targetURL)
                self.cleanupDiskIfNeeded()
                return targetURL
            } catch {
                try? self.fileManager.removeItem(at: partURL)
                throw error
            }
        }
        inFlightTasks[targetURL] = task
        lock.unlock()
        
        defer {
            lock.lock()
            inFlightTasks.removeValue(forKey: targetURL)
            lock.unlock()
        }
        
        return try await task.value
    }
    
    public func fetchFile(
        item: FileItem,
        transport: TransportMultiplexer,
        onProgress: (@Sendable (Double) -> Void)? = nil
    ) async throws -> URL {
        return try await fetchFile(
            item: item,
            downloader: { remotePath, targetURL, totalSize, progressCb in
                let stat = try await transport.prepareRead(actionId: UUID().uuidString, path: remotePath)
                let total = totalSize > 0 ? totalSize : stat.size
                try await transport.downloadFileStreaming(
                    actionId: UUID().uuidString,
                    remotePath: remotePath,
                    targetURL: targetURL,
                    totalSize: total
                ) { bytes in
                    let ratio = total > 0 ? min(1.0, Double(bytes) / Double(total)) : 0.0
                    progressCb?(ratio)
                }
            },
            onProgress: onProgress
        )
    }
    
    public func totalCacheSizeBytes() -> UInt64 {
        guard let files = try? fileManager.contentsOfDirectory(
            at: cacheDir,
            includingPropertiesForKeys: [.fileSizeKey]
        ) else { return 0 }
        
        var total: UInt64 = 0
        for url in files {
            let vals = try? url.resourceValues(forKeys: [.fileSizeKey])
            total += UInt64(vals?.fileSize ?? 0)
        }
        return total
    }
    
    public func clearCache() {
        guard let files = try? fileManager.contentsOfDirectory(
            at: cacheDir,
            includingPropertiesForKeys: nil
        ) else { return }
        
        for url in files {
            try? fileManager.removeItem(at: url)
        }
    }
    
    public func cleanupDiskIfNeeded() {
        let maxBytes = self.maxDiskBytes
        DispatchQueue.global(qos: .background).async { [weak self] in
            guard let self = self else { return }
            guard let files = try? self.fileManager.contentsOfDirectory(
                at: self.cacheDir,
                includingPropertiesForKeys: [.fileSizeKey, .contentModificationDateKey]
            ) else { return }
            
            var total: UInt64 = 0
            var fileList: [(url: URL, size: UInt64, date: Date)] = []
            for url in files {
                let vals = try? url.resourceValues(forKeys: [.fileSizeKey, .contentModificationDateKey])
                let sz = UInt64(vals?.fileSize ?? 0)
                let dt = vals?.contentModificationDate ?? Date.distantPast
                total += sz
                fileList.append((url, sz, dt))
            }
            
            if total > maxBytes {
                fileList.sort { $0.date < $1.date } // Самые старые первыми
                for item in fileList {
                    try? self.fileManager.removeItem(at: item.url)
                    total -= item.size
                    if total <= maxBytes * 3 / 4 { break }
                }
            }
        }
    }
}
