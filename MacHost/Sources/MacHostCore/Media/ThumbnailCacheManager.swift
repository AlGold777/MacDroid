import Foundation
import AppKit

public final class ThumbnailCacheManager: @unchecked Sendable {
    public static let shared = ThumbnailCacheManager()
    
    private let memoryCache = NSCache<NSString, NSImage>()
    private let fileManager = FileManager.default
    private let cacheDir: URL
    private let maxDiskBytes: UInt64 = 500 * 1024 * 1024 // 500 MB LRU Limit
    
    private init() {
        let paths = fileManager.urls(for: .cachesDirectory, in: .userDomainMask)
        cacheDir = paths[0].appendingPathComponent("com.macandroid.filemanager.thumbnails")
        try? fileManager.createDirectory(at: cacheDir, withIntermediateDirectories: true)
        memoryCache.totalCostLimit = 50 * 1024 * 1024 // 50 MB RAM limit
    }
    
    public func getThumbnail(for key: String) -> NSImage? {
        let nfcKey = key.precomposedStringWithCanonicalMapping
        if let cached = memoryCache.object(forKey: nfcKey as NSString) {
            return cached
        }
        let diskURL = cacheDir.appendingPathComponent(sanitizedKey(nfcKey))
        if let data = try? Data(contentsOf: diskURL), let img = NSImage(data: data) {
            memoryCache.setObject(img, forKey: nfcKey as NSString, cost: data.count)
            return img
        }
        return nil
    }
    
    public func storeThumbnail(image: NSImage, for key: String) {
        let nfcKey = key.precomposedStringWithCanonicalMapping
        memoryCache.setObject(image, forKey: nfcKey as NSString)
        
        guard let tiff = image.tiffRepresentation,
              let bitmap = NSBitmapImageRep(data: tiff),
              let png = bitmap.representation(using: .png, properties: [:]) else { return }
        
        let diskURL = cacheDir.appendingPathComponent(sanitizedKey(nfcKey))
        try? png.write(to: diskURL)
        cleanupDiskIfNeeded()
    }
    
    private func sanitizedKey(_ key: String) -> String {
        return key.addingPercentEncoding(withAllowedCharacters: .alphanumerics) ?? UUID().uuidString
    }
    
    private func cleanupDiskIfNeeded() {
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
            
            if total > self.maxDiskBytes {
                fileList.sort { $0.date < $1.date } // Самые старые первыми
                for item in fileList {
                    try? self.fileManager.removeItem(at: item.url)
                    total -= item.size
                    if total <= self.maxDiskBytes * 3 / 4 { break }
                }
            }
        }
    }
}
