import Foundation

/// Сервис рекурсивного поиска файлов как локально на Mac, так и удаленно на Android через SFTP
public final class SearchService: @unchecked Sendable {
    public static let shared = SearchService()
    
    public init() {}
    
    /// Рекурсивный поиск файлов в указанном каталоге
    public func search(
        query: String,
        in directoryPath: String,
        source: FileSource,
        localDriver: LocalFSDriver,
        remoteDriver: RemoteSFTPDriver,
        maxResults: Int = 500,
        onFound: @escaping @Sendable (FileItem) -> Void
    ) async throws -> [FileItem] {
        let cleanQuery = query.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !cleanQuery.isEmpty else { return [] }
        
        var results: [FileItem] = []
        
        if source == .localMac {
            let url = URL(fileURLWithPath: directoryPath)
            let keys: [URLResourceKey] = [.isRegularFileKey, .isDirectoryKey, .fileSizeKey, .contentModificationDateKey]
            
            guard let enumerator = FileManager.default.enumerator(
                at: url,
                includingPropertiesForKeys: keys,
                options: [.skipsHiddenFiles, .skipsPackageDescendants]
            ) else {
                return []
            }
            
            while let fileURL = enumerator.nextObject() as? URL {
                if Task.isCancelled || results.count >= maxResults { break }
                
                let fileName = fileURL.lastPathComponent
                if fileName.lowercased().contains(cleanQuery) {
                    let resourceValues = try? fileURL.resourceValues(forKeys: Set(keys))
                    let isDir = resourceValues?.isDirectory ?? false
                    let size = UInt64(resourceValues?.fileSize ?? 0)
                    let mtime = resourceValues?.contentModificationDate?.timeIntervalSince1970 ?? Date().timeIntervalSince1970
                    
                    let item = FileItem(
                        id: fileURL.path,
                        name: fileName,
                        path: fileURL.path,
                        size: size,
                        mtime: mtime,
                        isDirectory: isDir,
                        source: .localMac
                    )
                    results.append(item)
                    onFound(item)
                }
            }
        } else {
            // Удаленный рекурсивный поиск на телефоне.
            // ADB-поиск выполняется ТОЛЬКО на устройстве, привязанном к этой SFTP-сессии (serial обязателен):
            // иначе результаты могли бы относиться к другому подключённому телефону. Без привязки — только SFTP.
            if let boundDeviceId = remoteDriver.coordinator.deviceId, !boundDeviceId.isEmpty {
                let escapedPath = PhoneConnectionManager.shellEscape(directoryPath)
                let escapedPattern = PhoneConnectionManager.shellEscape("*" + cleanQuery + "*")

                // 1. Точное определение папок через -type d
                var dirPaths = Set<String>()
                let dirCmd = "find \(escapedPath) -maxdepth 6 -type d -iname \(escapedPattern) 2>/dev/null"
                let (dirStatus, dirOut) = PhoneConnectionManager.shared.executeAdbShell(command: dirCmd, deviceId: boundDeviceId)
                if dirStatus == 0 {
                    for line in dirOut.components(separatedBy: .newlines) {
                        let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
                        if !trimmed.isEmpty && trimmed != directoryPath {
                            dirPaths.insert(trimmed)
                        }
                    }
                }
                
                let cmd = "find \(escapedPath) -maxdepth 6 -iname \(escapedPattern) 2>/dev/null"
                let (status, output) = PhoneConnectionManager.shared.executeAdbShell(command: cmd, deviceId: boundDeviceId)
                if status == 0 && !output.isEmpty {
                    let lines = output.components(separatedBy: CharacterSet.newlines)
                    for line in lines {
                        if Task.isCancelled || results.count >= maxResults { break }
                        let trimmed = line.trimmingCharacters(in: CharacterSet.whitespacesAndNewlines)
                        if trimmed.isEmpty || trimmed == directoryPath { continue }
                        let fileName = URL(fileURLWithPath: trimmed).lastPathComponent
                        let isDir = dirPaths.contains(trimmed)
                        let item = FileItem(
                            id: trimmed,
                            name: fileName,
                            path: trimmed,
                            size: 0,
                            mtime: Date().timeIntervalSince1970,
                            isDirectory: isDir,
                            source: .remotePhone
                        )
                        results.append(item)
                        onFound(item)
                    }
                    if !results.isEmpty {
                        return results
                    }
                }
            }
            
            // Резервный SFTP-обход (для чистого Wi-Fi без ADB)
            var queue: [String] = [directoryPath]
            var visitedDirs = 0
            let maxDirs = 100 // Ограничение глубины для защиты от бесконечной рекурсии
            
            while !queue.isEmpty && visitedDirs < maxDirs && results.count < maxResults {
                if Task.isCancelled { break }
                let currentDir = queue.removeFirst()
                visitedDirs += 1
                
                do {
                    let items = try await remoteDriver.listDirectory(at: currentDir)
                    for item in items {
                        if item.name.lowercased().contains(cleanQuery) {
                            results.append(item)
                            onFound(item)
                        }
                        if item.isDirectory && !item.name.hasPrefix(".") {
                            queue.append(item.path)
                        }
                    }
                } catch {
                    continue
                }
            }
        }
        
        return results
    }
}
