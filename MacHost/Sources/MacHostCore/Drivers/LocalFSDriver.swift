import Foundation
import AppKit

public enum LocalFSDriverError: LocalizedError, Sendable {
    case trashUnavailable(path: String, reason: String)
    case itemNotFound(path: String)
    case alreadyExists(path: String)
    case freeSpaceUnavailable(path: String)

    public var errorDescription: String? {
        switch self {
        case .trashUnavailable(let path, let reason):
            return "Не удалось переместить в Корзину «\(path)»: \(reason). Во избежание потери данных автоматическое безвозвратное удаление заблокировано."
        case .itemNotFound(let path):
            return "Файл или каталог не найден: «\(path)»."
        case .alreadyExists(let path):
            return "Файл или каталог уже существует: «\(path)». Операция отменена, существующий объект не изменён."
        case .freeSpaceUnavailable(let path):
            return "Не удалось определить свободное место на томе для «\(path)»."
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
    
    /// Переименование/перенос БЕЗ перезаписи: если цель существует (и это не тот же объект по регистру),
    /// бросает `alreadyExists` и ничего не трогает.
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
            guard isSameFileSystemObject(sourcePath, destinationPath) else {
                throw LocalFSDriverError.alreadyExists(path: destinationPath)
            }
            // Переименование только регистра на нечувствительном к регистру томе
            try caseOnlyRename(from: sourcePath, to: destinationPath)
            return
        }
        try fm.moveItem(at: sourceURL, to: destURL)
    }

    /// Замещение существующего объекта (для коммитов передач при стратегии перезаписи).
    /// Старый объект переносится в Корзину; если Корзина недоступна — остаётся `.bak.*` рядом (не удаляется молча).
    public func replaceItem(from sourcePath: String, to destinationPath: String) async throws {
        let sourceURL = URL(fileURLWithPath: sourcePath)
        let destURL = URL(fileURLWithPath: destinationPath)
        let fm = FileManager.default

        guard fm.fileExists(atPath: sourceURL.path) else {
            throw LocalFSDriverError.itemNotFound(path: sourcePath)
        }
        if sourceURL.path == destURL.path {
            return
        }
        guard fm.fileExists(atPath: destURL.path) else {
            try fm.moveItem(at: sourceURL, to: destURL)
            return
        }
        if isSameFileSystemObject(sourcePath, destinationPath) {
            try caseOnlyRename(from: sourcePath, to: destinationPath)
            return
        }

        // Старый файл отодвигаем в бэкап рядом, новый ставим на его место
        let backupURL = destURL.deletingLastPathComponent().appendingPathComponent(".\(destURL.lastPathComponent).bak.\(UUID().uuidString)")
        try fm.moveItem(at: destURL, to: backupURL)
        do {
            try fm.moveItem(at: sourceURL, to: destURL)
        } catch {
            // Откат: возвращаем исходный объект на место
            try? fm.moveItem(at: backupURL, to: destURL)
            throw error
        }
        do {
            try fm.trashItem(at: backupURL, resultingItemURL: nil)
        } catch {
            // Корзина недоступна: бэкап остаётся, чтобы не потерять старые данные
            print("[LocalFSDriver] WARNING: старый файл «\(destURL.lastPathComponent)» оставлен как \(backupURL.lastPathComponent): \(error.localizedDescription)")
        }
    }

    /// Свободное место тома или nil, если значение недоступно (ошибка API / отрицательное значение).
    /// nil означает «неизвестно», а не «ноль байт».
    public func availableFreeSpace(at path: String) -> UInt64? {
        let url = URL(fileURLWithPath: path)
        guard let vals = try? url.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey]),
              let free = vals.volumeAvailableCapacityForImportantUsage,
              free >= 0 else {
            return nil
        }
        return UInt64(free)
    }

    public func checkFreeSpace(at path: String) async throws -> (free: UInt64, total: UInt64) {
        let url = URL(fileURLWithPath: path)
        guard let vals = try? url.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey, .volumeTotalCapacityKey]),
              let free = vals.volumeAvailableCapacityForImportantUsage, free >= 0,
              let total = vals.volumeTotalCapacity, total >= 0 else {
            throw LocalFSDriverError.freeSpaceUnavailable(path: path)
        }
        return (UInt64(free), UInt64(total))
    }

    /// Два пути указывают на один и тот же объект (device + inode).
    private func isSameFileSystemObject(_ a: String, _ b: String) -> Bool {
        let fm = FileManager.default
        guard let x = try? fm.attributesOfItem(atPath: a),
              let y = try? fm.attributesOfItem(atPath: b),
              let xi = x[.systemFileNumber] as? NSNumber,
              let yi = y[.systemFileNumber] as? NSNumber,
              let xd = x[.systemNumber] as? NSNumber,
              let yd = y[.systemNumber] as? NSNumber else {
            return false
        }
        return xi == yi && xd == yd
    }

    /// Переименование только регистра имени (POSIX rename не перезаписывает другой объект при совпадении inode).
    private func caseOnlyRename(from sourcePath: String, to destinationPath: String) throws {
        if rename(sourcePath, destinationPath) != 0 {
            let reason = String(cString: strerror(errno))
            throw NSError(domain: "LocalFSDriver", code: Int(errno), userInfo: [NSLocalizedDescriptionKey: "Не удалось переименовать «\(sourcePath)»: \(reason)"])
        }
    }
}
