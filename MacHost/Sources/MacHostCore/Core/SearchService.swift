import Foundation

/// Область поиска
public enum SearchScope: String, CaseIterable, Sendable {
    case currentFolder = "В этой папке"
    case everywhere = "Везде"
}

/// Сервис рекурсивного поиска файлов как локально на Mac, так и удаленно на Android через SFTP
public final class SearchService: @unchecked Sendable {
    public static let shared = SearchService()
    
    public init() {}
    
    /// Рекурсивный поиск файлов в указанном каталоге
    /// Рекурсивный поиск файлов в указанном каталоге
    public func search(
        query: String,
        in directoryPath: String,
        source: FileSource,
        localDriver: LocalFSDriver,
        remoteDriver: RemoteSFTPDriver,
        searchContent: Bool = true,
        maxResults: Int = 500,
        onFound: @escaping @Sendable (FileItem) -> Void
    ) async throws -> [FileItem] {
        let cleanQuery = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !cleanQuery.isEmpty else { return [] }
        let lowerQuery = cleanQuery.lowercased()
        
        var results: [FileItem] = []
        var seenPaths = Set<String>()
        
        if source == .localMac {
            // 1. Быстрый системный поиск через Spotlight (mdfind), как в Finder
            let spotlightPaths = searchSpotlight(query: cleanQuery, in: directoryPath, maxResults: maxResults)
            for path in spotlightPaths {
                if Task.isCancelled || results.count >= maxResults { break }
                guard !seenPaths.contains(path) else { continue }
                seenPaths.insert(path)
                
                let fileURL = URL(fileURLWithPath: path)
                let keys: [URLResourceKey] = [.isRegularFileKey, .isDirectoryKey, .fileSizeKey, .contentModificationDateKey, .creationDateKey]
                let resourceValues = try? fileURL.resourceValues(forKeys: Set(keys))
                let isDir = resourceValues?.isDirectory ?? false
                let size = UInt64(resourceValues?.fileSize ?? 0)
                let mtime = resourceValues?.contentModificationDate?.timeIntervalSince1970 ?? Date().timeIntervalSince1970
                let creationDate = resourceValues?.creationDate?.timeIntervalSince1970
                
                let item = FileItem(
                    id: path,
                    name: fileURL.lastPathComponent,
                    path: path,
                    size: size,
                    mtime: mtime,
                    isDirectory: isDir,
                    source: .localMac,
                    creationDate: creationDate
                )
                results.append(item)
                onFound(item)
            }
            
            // 2. Резервный прямой обход каталогов для неиндексированных Spotlight папок (например, /tmp, свежие файлы)
            let url = URL(fileURLWithPath: directoryPath)
            let keys: [URLResourceKey] = [.isRegularFileKey, .isDirectoryKey, .fileSizeKey, .contentModificationDateKey, .creationDateKey]
            
            if let enumerator = FileManager.default.enumerator(
                at: url,
                includingPropertiesForKeys: keys,
                options: [.skipsHiddenFiles, .skipsPackageDescendants]
            ) {
                while let fileURL = enumerator.nextObject() as? URL {
                    if Task.isCancelled || results.count >= maxResults { break }
                    let filePath = fileURL.path
                    if seenPaths.contains(filePath) { continue }
                    
                    let fileName = fileURL.lastPathComponent
                    let nameMatches = fileName.localizedCaseInsensitiveContains(cleanQuery)
                    
                    let resourceValues = try? fileURL.resourceValues(forKeys: Set(keys))
                    let isDir = resourceValues?.isDirectory ?? false
                    let size = UInt64(resourceValues?.fileSize ?? 0)
                    
                    var matched = nameMatches
                    if !matched && searchContent && !isDir && size > 0 && size < 5_000_000 {
                        matched = fileContainsText(url: fileURL, query: cleanQuery)
                    }
                    
                    if matched {
                        seenPaths.insert(filePath)
                        let mtime = resourceValues?.contentModificationDate?.timeIntervalSince1970 ?? Date().timeIntervalSince1970
                        let creationDate = resourceValues?.creationDate?.timeIntervalSince1970
                        
                        let item = FileItem(
                            id: filePath,
                            name: fileName,
                            path: filePath,
                            size: size,
                            mtime: mtime,
                            isDirectory: isDir,
                            source: .localMac,
                            creationDate: creationDate
                        )
                        results.append(item)
                        onFound(item)
                    }
                }
            }
        } else {
            // Удаленный рекурсивный поиск на телефоне.
            // ADB-поиск выполняется ТОЛЬКО на устройстве, привязанном к этой SFTP-сессии (serial обязателен):
            // иначе результаты могли бы относиться к другому подключённому телефону. Без привязки — только SFTP.
            if let boundDeviceId = remoteDriver.coordinator.deviceId, !boundDeviceId.isEmpty {
                let escapedPath = PhoneConnectionManager.shellEscape(directoryPath)
                let escapedPattern = PhoneConnectionManager.shellEscape("*" + lowerQuery + "*")
                
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
                
                // 2. Поиск по имени через find
                let cmd = "find \(escapedPath) -maxdepth 6 -iname \(escapedPattern) 2>/dev/null"
                let (status, output) = PhoneConnectionManager.shared.executeAdbShell(command: cmd, deviceId: boundDeviceId)
                if status == 0 && !output.isEmpty {
                    let lines = output.components(separatedBy: CharacterSet.newlines)
                    for line in lines {
                        if Task.isCancelled || results.count >= maxResults { break }
                        let trimmed = line.trimmingCharacters(in: CharacterSet.whitespacesAndNewlines)
                        if trimmed.isEmpty || trimmed == directoryPath || seenPaths.contains(trimmed) { continue }
                        seenPaths.insert(trimmed)
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
                }
                
                // 3. Поиск по содержимому через grep (если включен поиск по содержимому)
                if searchContent {
                    let escapedSearchText = PhoneConnectionManager.shellEscape(cleanQuery)
                    let grepCmd = "grep -rIli -m 1 \(escapedSearchText) \(escapedPath) 2>/dev/null"
                    let (grepStatus, grepOutput) = PhoneConnectionManager.shared.executeAdbShell(command: grepCmd, deviceId: boundDeviceId)
                    if grepStatus == 0 && !grepOutput.isEmpty {
                        let lines = grepOutput.components(separatedBy: CharacterSet.newlines)
                        for line in lines {
                            if Task.isCancelled || results.count >= maxResults { break }
                            let trimmed = line.trimmingCharacters(in: CharacterSet.whitespacesAndNewlines)
                            if trimmed.isEmpty || trimmed == directoryPath || seenPaths.contains(trimmed) { continue }
                            seenPaths.insert(trimmed)
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
                    }
                }
                
                if !results.isEmpty {
                    return results
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
                        if item.name.lowercased().contains(lowerQuery) {
                            if !seenPaths.contains(item.path) {
                                seenPaths.insert(item.path)
                                results.append(item)
                                onFound(item)
                            }
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
    
    // MARK: - Вспомогательные методы поиска на Mac
    
    /// Поиск через системную базу данных Spotlight (mdfind)
    private func searchSpotlight(query: String, in directoryPath: String, maxResults: Int) -> [String] {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/mdfind")
        process.arguments = ["-onlyin", directoryPath, query]
        
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice
        
        do {
            try process.run()
            process.waitUntilExit()
            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            guard let output = String(data: data, encoding: .utf8) else { return [] }
            
            var paths: [String] = []
            for line in output.components(separatedBy: .newlines) {
                let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
                if !trimmed.isEmpty && trimmed != directoryPath {
                    paths.append(trimmed)
                    if paths.count >= maxResults { break }
                }
            }
            return paths
        } catch {
            return []
        }
    }
    
    /// Проверка текстового содержимого файла
    private func fileContainsText(url: URL, query: String, maxBytes: Int = 2_000_000) -> Bool {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return false }
        defer { try? handle.close() }
        guard let data = try? handle.read(upToCount: maxBytes) else { return false }
        if let str = String(data: data, encoding: .utf8) {
            return str.localizedCaseInsensitiveContains(query)
        }
        if let str = String(data: data, encoding: .windowsCP1251) {
            return str.localizedCaseInsensitiveContains(query)
        }
        return false
    }
}
