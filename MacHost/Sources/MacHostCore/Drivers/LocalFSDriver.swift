import Foundation
import AppKit

public enum LocalFSDriverError: LocalizedError, Sendable {
    case trashUnavailable(path: String, reason: String)
    case itemNotFound(path: String)
    
    public var errorDescription: String? {
        switch self {
        case .trashUnavailable(let path, let reason):
            return "Не удалось переместить в Корзину «\(path)»: \(reason). Во избежание потери данных автоматическое безвозвратное удаление заблокировано."
        case .itemNotFound(let path):
            return "Файл или каталог не найден: «\(path)»."
        }
    }
}

public final class LocalFSDriver: FileSystemDriver, @unchecked Sendable {
    public init() {}
    
    public func listDirectory(at path: String) async throws -> [FileItem] {
        let url = URL(fileURLWithPath: path)
        let keys: Set<URLResourceKey> = [.fileSizeKey, .contentModificationDateKey, .isDirectoryKey, .isHiddenKey]
        
        let contents = try FileManager.default.contentsOfDirectory(
            at: url,
            includingPropertiesForKeys: Array(keys),
            options: []
        )
        
        return contents.compactMap { itemURL in
            guard let vals = try? itemURL.resourceValues(forKeys: keys) else {
                return nil
            }
            let isDir = vals.isDirectory ?? false
            let size = UInt64(vals.fileSize ?? 0)
            let mtime = vals.contentModificationDate?.timeIntervalSince1970 ?? 0
            let name = itemURL.lastPathComponent.precomposedStringWithCanonicalMapping
            
            return FileItem(
                id: itemURL.path.precomposedStringWithCanonicalMapping,
                name: name,
                path: itemURL.path.precomposedStringWithCanonicalMapping,
                size: isDir ? 0 : size,
                mtime: mtime,
                isDirectory: isDir,
                source: .localMac
            )
        }
    }
    
    public func createDirectory(at path: String) async throws {
        let url = URL(fileURLWithPath: path)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    }
    
    public func deleteItem(at path: String, moveToTrash: Bool) async throws {
        let url = URL(fileURLWithPath: path)
        let fm = FileManager.default
        guard fm.fileExists(atPath: path) else {
            throw LocalFSDriverError.itemNotFound(path: path)
        }
        
        if moveToTrash {
            do {
                var trashURL: NSURL?
                try fm.trashItem(at: url, resultingItemURL: &trashURL)
            } catch {
                // DAT-01 FIX: Никогда не удалять тихо в обход корзины. Выбрасываем явную ошибку.
                throw LocalFSDriverError.trashUnavailable(path: path, reason: error.localizedDescription)
            }
        } else {
            // Только при явном флаге moveToTrash: false (постоянное удаление)
            try fm.removeItem(at: url)
        }
    }
    
    public func renameItem(from sourcePath: String, to destinationPath: String) async throws {
        let sourceURL = URL(fileURLWithPath: sourcePath)
        let destURL = URL(fileURLWithPath: destinationPath)
        let fm = FileManager.default
        
        guard fm.fileExists(atPath: sourceURL.path) else {
            throw LocalFSDriverError.itemNotFound(path: sourcePath)
        }
        
        if sourceURL.path == destURL.path {
            return
        }
        
        if fm.fileExists(atPath: destURL.path) {
            // Создаем временный бэкап существующего файла назначения рядом
            let backupURL = destURL.deletingLastPathComponent().appendingPathComponent(".\(destURL.lastPathComponent).bak.\(UUID().uuidString)")
            try fm.moveItem(at: destURL, to: backupURL)
            
            do {
                try fm.moveItem(at: sourceURL, to: destURL)
                // Успех - удаляем бэкап
                try? fm.removeItem(at: backupURL)
            } catch {
                // Откат: возвращаем исходный destURL на место
                try? fm.moveItem(at: backupURL, to: destURL)
                throw error
            }
        } else {
            try fm.moveItem(at: sourceURL, to: destURL)
        }
    }
    
    public func checkFreeSpace(at path: String) async throws -> (free: UInt64, total: UInt64) {
        let url = URL(fileURLWithPath: path)
        let vals = try? url.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey, .volumeTotalCapacityKey])
        let free = UInt64(vals?.volumeAvailableCapacityForImportantUsage ?? 0)
        let total = UInt64(vals?.volumeTotalCapacity ?? 0)
        return (free, total)
    }
}
