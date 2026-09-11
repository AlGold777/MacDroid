import Foundation
import AppKit

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
        if moveToTrash {
            do {
                var trashURL: NSURL?
                try FileManager.default.trashItem(at: url, resultingItemURL: &trashURL)
            } catch {
                // Если корзина недоступна для этого тома, выполняем прямое удаление
                try FileManager.default.removeItem(at: url)
            }
        } else {
            try FileManager.default.removeItem(at: url)
        }
    }
    
    public func renameItem(from sourcePath: String, to destinationPath: String) async throws {
        let sourceURL = URL(fileURLWithPath: sourcePath)
        let destURL = URL(fileURLWithPath: destinationPath)
        let fm = FileManager.default
        
        if fm.fileExists(atPath: destURL.path) {
            _ = try fm.replaceItemAt(
                destURL,
                withItemAt: sourceURL,
                backupItemName: nil,
                options: []
            )
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
