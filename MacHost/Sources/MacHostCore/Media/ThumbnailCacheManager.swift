import Foundation
import AppKit
import ImageIO
import CryptoKit
import UniformTypeIdentifiers
import CoreImage
#if canImport(QuickLookThumbnailing)
import QuickLookThumbnailing
#endif

public final class ThumbnailCacheManager: @unchecked Sendable {
    public static let shared = ThumbnailCacheManager()
    
    private let memoryCache = NSCache<NSString, NSImage>()
    private let fileManager = FileManager.default
    private let cacheDir: URL
    private let maxDiskBytes: UInt64 = 500 * 1024 * 1024 // 500 MB LRU Limit
    // Полный скан диска (O(N) по файлам) не чаще раза в минуту, а не на каждое сохранение
    private let cleanupLock = NSLock()
    private var lastCleanupAt = Date.distantPast
    private static let cleanupInterval: TimeInterval = 60

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
            let wasThrottled = _isThrottledDueToTransfer
            _isThrottledDueToTransfer = newValue
            throttleLock.unlock()
            if wasThrottled && !newValue {
                // Ячейки, пропустившие загрузку эскиза во время трансфера, догружают его
                DispatchQueue.main.async {
                    NotificationCenter.default.post(name: Self.throttleLiftedNotification, object: nil)
                }
            }
        }
    }
    
    public static let throttleLiftedNotification = Notification.Name("ThumbnailCacheManager.throttleLifted")
    public static let cacheClearedNotification = Notification.Name("ThumbnailCacheManager.cacheCleared")
    
    private init() {
        let paths = fileManager.urls(for: .cachesDirectory, in: .userDomainMask)
        cacheDir = paths[0].appendingPathComponent("com.macandroid.filemanager.thumbnails")
        try? fileManager.createDirectory(at: cacheDir, withIntermediateDirectories: true)
        memoryCache.totalCostLimit = 50 * 1024 * 1024 // 50 MB RAM limit
    }
    
    /// Сброс кэша эскизов: полная очистка памяти и дисковой директории
    public func clearCache() {
        memoryCache.removeAllObjects()
        if let files = try? fileManager.contentsOfDirectory(at: cacheDir, includingPropertiesForKeys: nil) {
            for file in files {
                try? fileManager.removeItem(at: file)
            }
        }
        SSHTransportLog.write("THUMB_CACHE_CLEARED")
        DispatchQueue.main.async {
            NotificationCenter.default.post(name: Self.cacheClearedNotification, object: nil)
        }
    }
    
    /// Ключ эскиза: путь + размер + mtime. Изменённый на телефоне файл с тем же путём
    /// получает новый эскиз вместо устаревшего.
    public static func thumbnailKey(for item: FileItem) -> String {
        return "\(item.path)|\(item.size)|\(Int64(item.mtime))"
    }
    
    /// Мгновенная проверка только RAM-кэша (безопасно вызывать из главного потока при прокрутке)
    public func memoryThumbnail(for item: FileItem) -> NSImage? {
        let nfcKey = Self.thumbnailKey(for: item).precomposedStringWithCanonicalMapping
        if let cached = memoryCache.object(forKey: nfcKey as NSString) {
            if Self.isCorruptedGrayFrame(cached) {
                memoryCache.removeObject(forKey: nfcKey as NSString)
                return nil
            }
            return cached
        }
        return nil
    }
    
    public func getThumbnail(for item: FileItem) -> NSImage? {
        return getThumbnail(for: Self.thumbnailKey(for: item))
    }
    
    public func storeThumbnail(image: NSImage, for item: FileItem) {
        storeThumbnail(image: image, for: Self.thumbnailKey(for: item))
    }
    
    public func getThumbnail(for key: String) -> NSImage? {
        let nfcKey = key.precomposedStringWithCanonicalMapping
        if let cached = memoryCache.object(forKey: nfcKey as NSString) {
            if Self.isCorruptedGrayFrame(cached) {
                memoryCache.removeObject(forKey: nfcKey as NSString)
            } else {
                return cached
            }
        }
        let diskURL = cacheDir.appendingPathComponent(sanitizedKey(nfcKey))
        if let data = try? Data(contentsOf: diskURL), let img = NSImage(data: data) {
            if Self.isCorruptedGrayFrame(img) {
                try? fileManager.removeItem(at: diskURL)
                return nil
            }
            memoryCache.setObject(img, forKey: nfcKey as NSString, cost: Self.memoryCost(of: img))
            return img
        }
        return nil
    }
    
    public func storeThumbnail(image: NSImage, for key: String) {
        // Защита от записи поврежденных/серых кадров в кэш
        if Self.isCorruptedGrayFrame(image) {
            return
        }
        let nfcKey = key.precomposedStringWithCanonicalMapping
        memoryCache.setObject(image, forKey: nfcKey as NSString, cost: Self.memoryCost(of: image))
        
        guard let encoded = Self.encodeForDisk(image) else { return }
        let diskURL = cacheDir.appendingPathComponent(sanitizedKey(nfcKey))
        try? encoded.write(to: diskURL)
        cleanupDiskIfNeeded()
    }
    
    private static func memoryCost(of image: NSImage) -> Int {
        if let rep = image.representations.first, rep.pixelsWide > 0, rep.pixelsHigh > 0 {
            return rep.pixelsWide * rep.pixelsHigh * 4
        }
        return Int(image.size.width * image.size.height * 4)
    }
    
    /// Кодирование напрямую из CGImage без TIFF-посредника: JPEG для непрозрачных эскизов
    /// (в разы быстрее и меньше PNG), PNG — только при наличии альфа-канала.
    private static func encodeForDisk(_ image: NSImage) -> Data? {
        guard let cg = image.cgImage(forProposedRect: nil, context: nil, hints: nil) else { return nil }
        let hasAlpha: Bool
        switch cg.alphaInfo {
        case .none, .noneSkipFirst, .noneSkipLast: hasAlpha = false
        default: hasAlpha = true
        }
        let type = hasAlpha ? UTType.png : UTType.jpeg
        let data = NSMutableData()
        guard let dest = CGImageDestinationCreateWithData(data, type.identifier as CFString, 1, nil) else { return nil }
        let props: [CFString: Any] = hasAlpha ? [:] : [kCGImageDestinationLossyCompressionQuality: 0.82]
        CGImageDestinationAddImage(dest, cg, props as CFDictionary)
        guard CGImageDestinationFinalize(dest) else { return nil }
        return data as Data
    }
    
    /// Проверка кадра на битый/недодекодированный серый артефакт (truncated JPEG filler).
    /// При обрыве JPEG Apple ImageIO / libjpeg заполняет оставшуюся часть MCU-блоков
    /// плоским серым цветом (Y=128, Cb=128, Cr=128 -> sRGB ~128,128,128).
    /// Если нижняя треть кадра залита таким серым цветом, кадр признается поврежденным.
    public static func isCorruptedGrayFrame(_ image: NSImage) -> Bool {
        guard let cg = image.cgImage(forProposedRect: nil, context: nil, hints: nil) else {
            return false
        }
        return isCorruptedGrayFrame(cgImage: cg)
    }
    
    public static func isCorruptedGrayFrame(cgImage: CGImage) -> Bool {
        let width = cgImage.width
        let height = cgImage.height
        guard width >= 8, height >= 8 else { return false }
        
        let checkW = 32
        let checkH = 32
        var rawData = [UInt8](repeating: 0, count: checkW * checkH * 4)
        let colorSpace = CGColorSpaceCreateDeviceRGB()
        guard let ctx = CGContext(
            data: &rawData,
            width: checkW,
            height: checkH,
            bitsPerComponent: 8,
            bytesPerRow: checkW * 4,
            space: colorSpace,
            bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue
        ) else { return false }
        
        ctx.draw(cgImage, in: CGRect(x: 0, y: 0, width: checkW, height: checkH))
        
        // В CGContext (0,0) - нижний левый угол.
        // Нижняя треть - строки 0..<10 (из 32).
        let bottomRows = 10
        let totalBottomPixels = checkW * bottomRows
        var bottomGray = 0
        var bottomUnique = Set<UInt32>()
        
        for y in 0..<bottomRows {
            let rowOffset = y * checkW * 4
            for x in 0..<checkW {
                let p = rowOffset + x * 4
                let r = Int(rawData[p])
                let g = Int(rawData[p + 1])
                let b = Int(rawData[p + 2])
                
                // Truncated JPEG gray padding: sRGB (126...130)
                let isMidGray = abs(r - 128) <= 6 && abs(g - 128) <= 6 && abs(b - 128) <= 6 && abs(r - g) <= 3 && abs(g - b) <= 3
                if isMidGray {
                    bottomGray += 1
                }
                let colorKey = (UInt32(r) << 16) | (UInt32(g) << 8) | UInt32(b)
                bottomUnique.insert(colorKey)
            }
        }
        
        // Верхняя треть (строки 22..<32)
        let topRowsStart = checkH - bottomRows
        var topGray = 0
        var topUnique = Set<UInt32>()
        
        for y in topRowsStart..<checkH {
            let rowOffset = y * checkW * 4
            for x in 0..<checkW {
                let p = rowOffset + x * 4
                let r = Int(rawData[p])
                let g = Int(rawData[p + 1])
                let b = Int(rawData[p + 2])
                
                let isMidGray = abs(r - 128) <= 6 && abs(g - 128) <= 6 && abs(b - 128) <= 6 && abs(r - g) <= 3 && abs(g - b) <= 3
                if isMidGray {
                    topGray += 1
                }
                let colorKey = (UInt32(r) << 16) | (UInt32(g) << 8) | UInt32(b)
                topUnique.insert(colorKey)
            }
        }
        
        let bottomGrayRatio = Double(bottomGray) / Double(totalBottomPixels)
        let topGrayRatio = Double(topGray) / Double(totalBottomPixels)
        
        // Признак truncated JPEG: нижняя треть залита серым заполнителем libjpeg (>= 75%),
        // в то время как верхняя часть содержит полезный кадр
        if bottomGrayRatio >= 0.75 && (topGrayRatio < 0.60 || (topUnique.count >= 16 && bottomUnique.count <= 6)) {
            return true
        }
        
        return false
    }
    
    // MARK: - Modern 2026 Asynchronous Thumbnail Pipeline
    
    private let remoteQueue = RemoteThumbnailQueue()
    
    private static let supportedImageExtensions: Set<String> = [
        "jpg", "jpeg", "png", "heic", "heif", "webp", "gif", "bmp", "tiff", "tif", "ico", "avif", "dng"
    ]
    
    /// Асинхронно получает или генерирует миниатюру для элемента файла.
    /// `targetSize` — размер в пикселях (вызывающий код уже учитывает Retina).
    public func loadThumbnail(
        for item: FileItem,
        targetSize: CGSize = CGSize(width: 256, height: 256),
        transport: TransportMultiplexer? = nil
    ) async -> NSImage? {
        if item.isDirectory { return nil }
        
        let ext = URL(fileURLWithPath: item.name).pathExtension.lowercased()
        let isImage = Self.supportedImageExtensions.contains(ext)
        let maxPixel = max(targetSize.width, targetSize.height)
        let startUptime = ProcessInfo.processInfo.systemUptime
        
        // 1. Проверяем кэш миниатюр (память и диск) — вне главного потока
        if let cached = getThumbnail(for: item) {
            SSHTransportLog.verbose("THUMB_CACHE_HIT path=\(item.name)")
            return cached
        }
        
        // 2. Локальный файл на Mac
        if item.source == .localMac {
            let url = URL(fileURLWithPath: item.path)
            guard FileManager.default.fileExists(atPath: item.path) else {
                SSHTransportLog.verbose("THUMB_SKIP reason=noLocalFile path=\(item.name)")
                return nil
            }
            
            // Быстрая генерация через ImageIO / CGImageSource
            if isImage, let downsampled = Self.createThumbnail(from: url, maxPixelSize: maxPixel) {
                if !Self.isCorruptedGrayFrame(downsampled) {
                    storeThumbnail(image: downsampled, for: item)
                    return downsampled
                }
            }
            
            // Для документов/PDF/видео: QuickLookThumbnailing
            #if canImport(QuickLookThumbnailing)
            let request = QLThumbnailGenerator.Request(
                fileAt: url,
                size: CGSize(width: maxPixel / 2, height: maxPixel / 2),
                scale: 2.0,
                representationTypes: .thumbnail
            )
            if let rep = try? await QLThumbnailGenerator.shared.generateBestRepresentation(for: request) {
                let img = rep.nsImage
                if !Self.isCorruptedGrayFrame(img) {
                    storeThumbnail(image: img, for: item)
                    return img
                }
            }
            #endif
            
            return nil
        }
        
        // 3. Удаленный файл на телефоне (Android)
        guard isImage else {
            // Для не-графических файлов не скачиваем по SFTP в фоне
            return nil
        }
        
        SSHTransportLog.verbose("THUMB_START path=\(item.name) size=\(item.size)")
        
        // Если уже есть в локальном QuickLook кэше
        if let cachedLocalURL = QuickLookCacheManager.shared.isCached(for: item) {
            if let img = Self.createThumbnail(from: cachedLocalURL, maxPixelSize: maxPixel),
               !Self.isCorruptedGrayFrame(img) {
                storeThumbnail(image: img, for: item)
                let elapsedMs = Int((ProcessInfo.processInfo.systemUptime - startUptime) * 1000)
                SSHTransportLog.verbose("THUMB_DECODE ok w×h=\(Int(img.size.width))x\(Int(img.size.height)) path=\(item.name)")
                SSHTransportLog.verbose("THUMB_DONE path=\(item.name) ms=\(elapsedMs)")
                return img
            }
        }
        
        // Для файлов размером больше 60 МБ фоновую подгрузку эскиза пропускаем
        guard item.size <= 60 * 1024 * 1024 else {
            SSHTransportLog.verbose("THUMB_SKIP reason=size path=\(item.name)")
            return nil
        }
        guard let transport = transport else {
            SSHTransportLog.verbose("THUMB_SKIP reason=noTransport path=\(item.name)")
            return nil
        }
        
        // QoS Transfer Arbiter: если активен трансфер файлов, приостанавливаем удалённые превью
        guard !isThrottledDueToTransfer else {
            SSHTransportLog.verbose("THUMB_SKIP reason=throttle path=\(item.name)")
            return nil
        }
        
        // Ограничиваем параллельные запросы к телефону. Очередь LIFO: первыми обслуживаются
        // только что показанные ячейки; ячейки, ушедшие с экрана (отменённые задачи), не ждут.
        guard await remoteQueue.acquire() else {
            SSHTransportLog.verbose("THUMB_SKIP reason=cancelled path=\(item.name)")
            return nil
        }
        defer { Task { await remoteQueue.release() } }
        guard !Task.isCancelled else {
            SSHTransportLog.verbose("THUMB_SKIP reason=cancelled path=\(item.name)")
            return nil
        }
        
        // Оптимизация: сначала читаем первые 128 КБ. Фото JPEG со смартфонов содержат
        // готовый EXIF-эскиз в начале файла — берём именно его, не декодируя обрезанный кадр.
        let prefixLen = UInt32(min(item.size, 128 * 1024))
        if prefixLen > 1024 {
            do {
                let prefixData = try await transport.readChunk(remotePath: item.path, offset: 0, length: prefixLen)
                let isWholeFile = UInt64(prefixData.count) >= item.size
                let hasExif = Self.exifThumbnailJPEG(from: prefixData) != nil
                SSHTransportLog.verbose("THUMB_PREFIX path=\(item.name) bytes=\(prefixData.count) exif=\(hasExif ? "yes" : "no") isWhole=\(isWholeFile)")
                
                let fastImg: NSImage?
                if isWholeFile {
                    fastImg = Self.createThumbnail(from: prefixData, maxPixelSize: maxPixel)
                } else {
                    fastImg = Self.embeddedThumbnail(from: prefixData, maxPixelSize: maxPixel)
                }
                
                if let fastImg = fastImg, !Self.isCorruptedGrayFrame(fastImg) {
                    storeThumbnail(image: fastImg, for: item)
                    let elapsedMs = Int((ProcessInfo.processInfo.systemUptime - startUptime) * 1000)
                    SSHTransportLog.verbose("THUMB_DECODE ok w×h=\(Int(fastImg.size.width))x\(Int(fastImg.size.height)) path=\(item.name)")
                    SSHTransportLog.verbose("THUMB_DONE path=\(item.name) ms=\(elapsedMs)")
                    return fastImg
                }
            } catch {
                SSHTransportLog.write("THUMB_PREFIX_ERR path=\(item.name) err=\(error.localizedDescription)")
            }
        }
        
        guard !Task.isCancelled else {
            SSHTransportLog.verbose("THUMB_SKIP reason=cancelled path=\(item.name)")
            return nil
        }
        
        // Если префикса недостаточно (HEIC, WebP, DNG, фото без встроенного EXIF),
        // загружаем файл в фоне до 25 МБ
        guard item.size <= 25 * 1024 * 1024 else {
            SSHTransportLog.verbose("THUMB_SKIP reason=sizeAbove25MB path=\(item.name)")
            return nil
        }
        
        SSHTransportLog.verbose("THUMB_FULL_DL_START path=\(item.name) size=\(item.size)")
        do {
            let localURL = try await QuickLookCacheManager.shared.fetchFile(item: item, transport: transport)
            SSHTransportLog.verbose("THUMB_FULL_DL ok path=\(item.name)")
            if let img = Self.createThumbnail(from: localURL, maxPixelSize: maxPixel),
               !Self.isCorruptedGrayFrame(img) {
                storeThumbnail(image: img, for: item)
                let elapsedMs = Int((ProcessInfo.processInfo.systemUptime - startUptime) * 1000)
                SSHTransportLog.verbose("THUMB_DECODE ok w×h=\(Int(img.size.width))x\(Int(img.size.height)) path=\(item.name)")
                SSHTransportLog.verbose("THUMB_DONE path=\(item.name) ms=\(elapsedMs)")
                return img
            } else {
                SSHTransportLog.write("THUMB_DECODE nil path=\(item.name)")
            }
        } catch {
            SSHTransportLog.write("THUMB_FULL_DL err=\(error.localizedDescription) path=\(item.name)")
            return nil
        }
        
        return nil
    }
    
    /// Встроенный EXIF-эскиз из неполных данных (префикса JPEG).
    /// ВАЖНО: Декодирование производится строго из выделенного thumbnail-JPEG байт-потока,
    /// а не из усеченного основного кадра файла, что исключает появление серых полос/кадров.
    public static func embeddedThumbnail(from data: Data, maxPixelSize: CGFloat) -> NSImage? {
        guard let (thumbJPEG, orientation) = exifThumbnailDataAndOrientation(from: data),
              let thumbSource = CGImageSourceCreateWithData(thumbJPEG as CFData, nil),
              let thumbProps = CGImageSourceCopyPropertiesAtIndex(thumbSource, 0, nil) as? [CFString: Any],
              let tw = thumbProps[kCGImagePropertyPixelWidth] as? Int,
              let th = thumbProps[kCGImagePropertyPixelHeight] as? Int else {
            return nil
        }
        let thumbMax = max(tw, th)
        // Принимаем эскиз если он хотя бы 80 px (быстрый эскиз для любого масштаба сетки)
        guard thumbMax >= 80 else { return nil }
        
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceShouldCacheImmediately: true,
            kCGImageSourceThumbnailMaxPixelSize: maxPixelSize
        ]
        // Декодируем ИМЕННО из thumbSource (целостный thumbnail), а не из data
        guard let cgImage = CGImageSourceCreateThumbnailAtIndex(thumbSource, 0, options as CFDictionary) else {
            return nil
        }
        
        // Проверяем ориентацию: если thumbJPEG не имел встроенного тега ориентации,
        // но ориентация была в IFD0 исходного файла (orientation 5..8 меняет местами ширину/высоту)
        var finalCGImage = cgImage
        let isSwapped = orientation >= 5 && orientation <= 8
        let alreadySwapped = (isSwapped && finalCGImage.height > finalCGImage.width && tw >= th)
        if orientation > 1 && !alreadySwapped {
            let propOrientation = CGImagePropertyOrientation(rawValue: UInt32(orientation)) ?? .up
            let ci = CIImage(cgImage: finalCGImage).oriented(propOrientation)
            let ciContext = CIContext(options: nil)
            if let oriented = ciContext.createCGImage(ci, from: ci.extent) {
                finalCGImage = oriented
            }
        }
        
        let result = NSImage(cgImage: finalCGImage, size: NSSize(width: finalCGImage.width, height: finalCGImage.height))
        if isCorruptedGrayFrame(result) {
            return nil
        }
        return result
    }
    
    /// Извлечение данных JPEG-эскиза и ориентации из структуры EXIF (APP1 -> IFD0 & IFD1).
    public static func exifThumbnailDataAndOrientation(from data: Data) -> (data: Data, orientation: Int)? {
        let b = [UInt8](data)
        guard b.count > 12, b[0] == 0xFF, b[1] == 0xD8 else { return nil }
        
        var pos = 2
        while pos + 4 <= b.count {
            guard b[pos] == 0xFF else { return nil }
            let marker = b[pos + 1]
            if marker == 0xFF { pos += 1; continue }
            if marker == 0xD8 || marker == 0x01 || (0xD0...0xD7).contains(marker) { pos += 2; continue }
            if marker == 0xDA || marker == 0xD9 { return nil } // начались данные кадра — APP1 уже не будет
            let len = Int(b[pos + 2]) << 8 | Int(b[pos + 3])
            let segStart = pos + 4
            let segEnd = pos + 2 + len
            guard len >= 2, segEnd <= b.count else { return nil }
            if marker == 0xE1, segEnd - segStart >= 14,
               b[segStart] == 0x45, b[segStart + 1] == 0x78, b[segStart + 2] == 0x69, b[segStart + 3] == 0x66,
               b[segStart + 4] == 0, b[segStart + 5] == 0 { // "Exif\0\0"
                return exifThumbnailBytesAndOrientation(in: b, tiffStart: segStart + 6, end: segEnd)
            }
            pos = segEnd
        }
        return nil
    }
    
    /// Байты JPEG-эскиза из EXIF (IFD1: JPEGInterchangeFormat 0x0201 / Length 0x0202).
    public static func exifThumbnailJPEG(from data: Data) -> Data? {
        return exifThumbnailDataAndOrientation(from: data)?.data
    }
    
    private static func exifThumbnailBytesAndOrientation(in b: [UInt8], tiffStart t: Int, end: Int) -> (data: Data, orientation: Int)? {
        guard end - t >= 8 else { return nil }
        let little: Bool
        if b[t] == 0x49 && b[t + 1] == 0x49 { little = true }
        else if b[t] == 0x4D && b[t + 1] == 0x4D { little = false }
        else { return nil }
        
        func u16(_ o: Int) -> Int? {
            guard o >= t, o + 2 <= end else { return nil }
            return little ? Int(b[o]) | Int(b[o + 1]) << 8 : Int(b[o]) << 8 | Int(b[o + 1])
        }
        func u32(_ o: Int) -> Int? {
            guard o >= t, o + 4 <= end else { return nil }
            return little
                ? Int(b[o]) | Int(b[o + 1]) << 8 | Int(b[o + 2]) << 16 | Int(b[o + 3]) << 24
                : Int(b[o]) << 24 | Int(b[o + 1]) << 16 | Int(b[o + 2]) << 8 | Int(b[o + 3])
        }
        
        guard u16(t + 2) == 42, let ifd0 = u32(t + 4), ifd0 > 0,
              let count0 = u16(t + ifd0),
              let ifd1 = u32(t + ifd0 + 2 + count0 * 12), ifd1 > 0,
              let count1 = u16(t + ifd1), count1 > 0, count1 < 256 else { return nil }
        
        var orientation = 1
        for i in 0..<count0 {
            let e = t + ifd0 + 2 + i * 12
            guard let tag = u16(e) else { continue }
            if tag == 0x0112 {
                if let val = u16(e + 8), val >= 1 && val <= 8 {
                    orientation = val
                }
            }
        }
        
        var jpegOffset: Int?
        var jpegLength: Int?
        for i in 0..<count1 {
            let e = t + ifd1 + 2 + i * 12
            guard let tag = u16(e), let value = u32(e + 8) else { return nil }
            if tag == 0x0201 { jpegOffset = value }
            if tag == 0x0202 { jpegLength = value }
        }
        guard let off = jpegOffset, let len = jpegLength, len > 4 else { return nil }
        let lo = t + off
        let hi = lo + len
        guard lo >= t, hi <= end, b[lo] == 0xFF, b[lo + 1] == 0xD8 else { return nil }
        return (Data(b[lo..<hi]), orientation)
    }
    
    public static func createThumbnail(from data: Data, maxPixelSize: CGFloat) -> NSImage? {
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceShouldCacheImmediately: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: maxPixelSize
        ]
        guard let source = CGImageSourceCreateWithData(data as CFData, nil),
              let cgImage = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary) else {
            return nil
        }
        return NSImage(cgImage: cgImage, size: NSSize(width: cgImage.width, height: cgImage.height))
    }
    
    public static func createThumbnail(from url: URL, maxPixelSize: CGFloat) -> NSImage? {
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceShouldCacheImmediately: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: maxPixelSize
        ]
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
              let cgImage = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary) else {
            return NSImage(contentsOf: url)
        }
        return NSImage(cgImage: cgImage, size: NSSize(width: cgImage.width, height: cgImage.height))
    }
    
    /// Имя файла на диске: фиксированной длины (SHA-256 hex). Исходный ключ содержит путь,
    /// который для длинных путей Android превышает лимит имени файла (255 байт).
    private func sanitizedKey(_ key: String) -> String {
        SHA256.hash(data: Data(key.utf8)).map { String(format: "%02x", $0) }.joined()
    }

    private func cleanupDiskIfNeeded() {
        cleanupLock.lock()
        let now = Date()
        guard now.timeIntervalSince(lastCleanupAt) >= Self.cleanupInterval else {
            cleanupLock.unlock()
            return
        }
        lastCleanupAt = now
        cleanupLock.unlock()

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

/// Актор-семафор для ограничения параллельных скачиваний эскизов с телефона.
/// LIFO + отмена: при быстрой прокрутке сетки ячейки, ушедшие с экрана, снимаются
/// из очереди, а свежие (видимые) обслуживаются первыми.
private actor RemoteThumbnailQueue {
    private var activeCount = 0
    private let maxConcurrent = 3
    private var waiters: [(id: UUID, cont: CheckedContinuation<Bool, Never>)] = []
    
    /// true — слот получен (обязателен release()); false — задача отменена, слот не выдан
    func acquire() async -> Bool {
        if Task.isCancelled { return false }
        if activeCount < maxConcurrent {
            activeCount += 1
            return true
        }
        let id = UUID()
        return await withTaskCancellationHandler {
            await withCheckedContinuation { (cont: CheckedContinuation<Bool, Never>) in
                waiters.append((id, cont))
            }
        } onCancel: {
            Task { await self.cancelWaiter(id) }
        }
    }
    
    private func cancelWaiter(_ id: UUID) {
        guard let idx = waiters.firstIndex(where: { $0.id == id }) else { return }
        let waiter = waiters.remove(at: idx)
        waiter.cont.resume(returning: false)
    }
    
    func release() {
        if let next = waiters.popLast() {
            next.cont.resume(returning: true)
        } else {
            activeCount = max(0, activeCount - 1)
        }
    }
}
