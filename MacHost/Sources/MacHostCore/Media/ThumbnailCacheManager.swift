import Foundation
import AppKit
import ImageIO
#if canImport(QuickLookThumbnailing)
import QuickLookThumbnailing
#endif

public final class ThumbnailCacheManager: @unchecked Sendable {
    public static let shared = ThumbnailCacheManager()
    
    private let memoryCache = NSCache<NSString, NSImage>()
    private let fileManager = FileManager.default
    private let cacheDir: URL
    private let maxDiskBytes: UInt64 = 500 * 1024 * 1024 // 500 MB LRU Limit
    
    // Transfer QoS Arbiter: флаг приоритизации трансфера перед подгрузкой эскизов
    private let throttleLock = NSLock()
    private var _isThrottledDueToTransfer = false
    public var isThrottledDueToTransfer: Bool {
        get {
            throttleLock.lock()
            defer { throttleLock.unlock() }
            return _isThrottledDueToTransfer
        }
        set {
            throttleLock.lock()
            _isThrottledDueToTransfer = newValue
            throttleLock.unlock()
        }
    }
    
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
    
    // MARK: - Modern 2026 Asynchronous Thumbnail Pipeline
    
    private let remoteQueue = RemoteThumbnailQueue()
    
    private static let supportedImageExtensions: Set<String> = [
        "jpg", "jpeg", "png", "heic", "heif", "webp", "gif", "bmp", "tiff", "tif", "ico", "avif"
    ]
    
    /// Асинхронно получает или генерирует миниатюру для элемента файла
    public func loadThumbnail(
        for item: FileItem,
        targetSize: CGSize = CGSize(width: 256, height: 256),
        transport: TransportMultiplexer? = nil
    ) async -> NSImage? {
        if item.isDirectory { return nil }
        
        let ext = URL(fileURLWithPath: item.name).pathExtension.lowercased()
        let isImage = Self.supportedImageExtensions.contains(ext)
        
        // 1. Проверяем кэш миниатюр (память и диск)
        if let cached = getThumbnail(for: item.path) {
            return cached
        }
        
        // 2. Локальный файл на Mac
        if item.source == .localMac {
            let url = URL(fileURLWithPath: item.path)
            guard FileManager.default.fileExists(atPath: item.path) else { return nil }
            
            // Быстрая генерация через ImageIO / CGImageSource
            if isImage, let downsampled = Self.createThumbnail(from: url, maxPixelSize: max(targetSize.width, targetSize.height)) {
                storeThumbnail(image: downsampled, for: item.path)
                return downsampled
            }
            
            // Для документов/PDF/видео: QuickLookThumbnailing
            #if canImport(QuickLookThumbnailing)
            let request = QLThumbnailGenerator.Request(
                fileAt: url,
                size: targetSize,
                scale: NSScreen.main?.backingScaleFactor ?? 2.0,
                representationTypes: .thumbnail
            )
            if let rep = try? await QLThumbnailGenerator.shared.generateBestRepresentation(for: request) {
                let img = rep.nsImage
                storeThumbnail(image: img, for: item.path)
                return img
            }
            #endif
            
            return nil
        }
        
        // 3. Удаленный файл на телефоне (Android)
        guard isImage else {
            // Для не-графических файлов не скачиваем по SFTP в фоне
            return nil
        }
        
        // Если уже есть в локальном QuickLook кэше
        if let cachedLocalURL = QuickLookCacheManager.shared.isCached(for: item) {
            if let img = Self.createThumbnail(from: cachedLocalURL, maxPixelSize: max(targetSize.width, targetSize.height)) {
                storeThumbnail(image: img, for: item.path)
                return img
            }
        }
        
        // Для файлов размером больше 60 МБ фоновую подгрузку эскиза пропускаем
        guard item.size <= 60 * 1024 * 1024, let transport = transport else { return nil }
        
        // QoS Transfer Arbiter: если активен трансфер файлов, приостанавливаем удалённые превью
        guard !isThrottledDueToTransfer else { return nil }
        
        // Ограничиваем параллельные запросы к телефону (не более 3 одновременно)
        await remoteQueue.acquire()
        defer { Task { await remoteQueue.release() } }
        
        // Оптимизация: Сначала пробуем быстро прочитать первые 128 КБ заголовка.
        // Большинство фото JPEG/HEIC со смартфонов содержат готовый встроенный EXIF thumbnail в начале файла!
        let prefixLen = UInt32(min(item.size, 128 * 1024))
        if prefixLen > 1024,
           let prefixData = try? await transport.readChunk(remotePath: item.path, offset: 0, length: prefixLen),
           let fastImg = Self.createThumbnail(from: prefixData, maxPixelSize: max(targetSize.width, targetSize.height)) {
            storeThumbnail(image: fastImg, for: item.path)
            return fastImg
        }
        
        // Если префикса недостаточно (нет встроенного EXIF), скачиваем только если файл не огромный (до 15 МБ)
        guard item.size <= 15 * 1024 * 1024 else { return nil }
        
        do {
            let localURL = try await QuickLookCacheManager.shared.fetchFile(item: item, transport: transport)
            if let img = Self.createThumbnail(from: localURL, maxPixelSize: max(targetSize.width, targetSize.height)) {
                storeThumbnail(image: img, for: item.path)
                return img
            }
        } catch {
            // Ошибка загрузки эскиза с телефона - возвращаем nil (отобразится иконка типа)
            return nil
        }
        
        return nil
    }
    
    private static func createThumbnail(from data: Data, maxPixelSize: CGFloat) -> NSImage? {
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceShouldCacheImmediately: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: maxPixelSize * 2.0
        ]
        guard let source = CGImageSourceCreateWithData(data as CFData, nil),
              let cgImage = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary) else {
            return nil
        }
        return NSImage(cgImage: cgImage, size: NSSize(width: cgImage.width, height: cgImage.height))
    }
    
    private static func createThumbnail(from url: URL, maxPixelSize: CGFloat) -> NSImage? {
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceShouldCacheImmediately: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: maxPixelSize * 2.0 // для Retina
        ]
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
              let cgImage = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary) else {
            return NSImage(contentsOf: url)
        }
        return NSImage(cgImage: cgImage, size: NSSize(width: cgImage.width, height: cgImage.height))
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

/// Актор-семафор для ограничения параллельных скачиваний эскизов с телефона
private actor RemoteThumbnailQueue {
    private var activeCount = 0
    private let maxConcurrent = 3
    private var waiters: [CheckedContinuation<Void, Never>] = []
    
    func acquire() async {
        if activeCount < maxConcurrent {
            activeCount += 1
            return
        }
        await withCheckedContinuation { cont in
            waiters.append(cont)
        }
    }
    
    func release() {
        if !waiters.isEmpty {
            let next = waiters.removeFirst()
            next.resume()
        } else {
            activeCount = max(0, activeCount - 1)
        }
    }
}
