import Foundation

public final class ArchiveService: Sendable {
    public static let shared = ArchiveService()
    
    public enum ArchiveFormat: String, CaseIterable, Identifiable, Sendable {
        case zip = "ZIP архив (.zip)"
        case tarGz = "TAR.GZ сжатый архив (.tar.gz)"
        case tar = "TAR архив (.tar)"
        
        public var id: String { rawValue }
        
        public var fileExtension: String {
            switch self {
            case .zip: return "zip"
            case .tarGz: return "tar.gz"
            case .tar: return "tar"
            }
        }
    }
    
    public init() {}
    
    /// Проверяет, является ли файл поддерживаемым архивом по расширению
    public static func isArchive(fileName: String) -> Bool {
        let lower = fileName.lowercased()
        let archiveExtensions = [
            ".zip", ".tar.gz", ".tgz", ".tar.bz2", ".tbz2", ".tbz",
            ".tar.xz", ".txz", ".tar", ".gz", ".bz2", ".xz",
            ".7z", ".rar", ".apk", ".jar", ".ipa"
        ]
        return archiveExtensions.contains { lower.hasSuffix($0) }
    }
    
    /// Распаковывает архив в указанную директорию назначения
    public func extractArchive(
        archivePath: String,
        destinationPath: String
    ) async throws {
        guard FileManager.default.fileExists(atPath: archivePath) else {
            throw NSError(domain: "ArchiveService", code: 2, userInfo: [NSLocalizedDescriptionKey: "Архив не найден: \(archivePath)"])
        }
        
        let destURL = URL(fileURLWithPath: destinationPath)
        try FileManager.default.createDirectory(at: destURL, withIntermediateDirectories: true)
        
        let lowerName = URL(fileURLWithPath: archivePath).lastPathComponent.lowercased()
        
        return try await withCheckedThrowingContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                let process = Process()
                let errPipe = Pipe()
                process.standardError = errPipe
                
                if lowerName.hasSuffix(".zip") || lowerName.hasSuffix(".apk") || lowerName.hasSuffix(".jar") || lowerName.hasSuffix(".ipa") {
                    process.executableURL = URL(fileURLWithPath: "/usr/bin/ditto")
                    process.arguments = ["-x", "-k", archivePath, destinationPath]
                } else {
                    // tar, tar.gz, tgz, tar.bz2, tbz, tar.xz, txz
                    process.executableURL = URL(fileURLWithPath: "/usr/bin/tar")
                    process.arguments = ["-xf", archivePath, "-C", destinationPath]
                }
                
                do {
                    try process.run()
                    // stderr читаем ДО waitUntilExit: иначе при выводе >64 КБ процесс блокируется на записи в pipe (дедлок)
                    let errData = errPipe.fileHandleForReading.readDataToEndOfFile()
                    process.waitUntilExit()

                    if process.terminationStatus == 0 {
                        continuation.resume()
                    } else {
                        let errMsg = String(data: errData, encoding: .utf8) ?? "Неизвестная ошибка распаковки"
                        continuation.resume(throwing: NSError(
                            domain: "ArchiveService",
                            code: Int(process.terminationStatus),
                            userInfo: [NSLocalizedDescriptionKey: "Ошибка распаковки архива: \(errMsg)"]
                        ))
                    }
                } catch {
                    continuation.resume(throwing: error)
                }
            }
        }
    }
    
    /// Создает архив из указанных путей (файлы и/или папки)
    public func createArchive(
        sources: [String],
        destinationPath: String,
        format: ArchiveFormat = .zip
    ) async throws {
        guard !sources.isEmpty else {
            throw NSError(domain: "ArchiveService", code: 1, userInfo: [NSLocalizedDescriptionKey: "Нет файлов для архивирования"])
        }
        
        let destURL = URL(fileURLWithPath: destinationPath).standardizedFileURL
        let fm = FileManager.default

        // Один источник = одна папка: относительные имена архива берутся от общей родительской папки.
        // Источники из разных папок (с одинаковыми lastPathComponent) не поддерживаются — отказ вместо порчи архива.
        let parentPaths = Set(sources.map { URL(fileURLWithPath: $0).standardizedFileURL.deletingLastPathComponent().path })
        guard parentPaths.count == 1 else {
            throw NSError(domain: "ArchiveService", code: 3, userInfo: [NSLocalizedDescriptionKey: "Архивирование файлов из разных папок за один раз не поддерживается. Выделите файлы из одной папки."])
        }

        // Нельзя писать архив поверх источника и поверх каталога/не-файла
        let sourcePaths = Set(sources.map { URL(fileURLWithPath: $0).standardizedFileURL.path })
        if sourcePaths.contains(destURL.path) {
            throw NSError(domain: "ArchiveService", code: 4, userInfo: [NSLocalizedDescriptionKey: "Имя архива совпадает с одним из архивируемых файлов"])
        }
        if fm.fileExists(atPath: destURL.path) {
            let type = (try? fm.attributesOfItem(atPath: destURL.path)[.type] as? FileAttributeType) ?? nil
            guard type == .typeRegular else {
                throw NSError(domain: "ArchiveService", code: 5, userInfo: [NSLocalizedDescriptionKey: "По пути назначения находится не файл архива: «\(destURL.lastPathComponent)». Архив не создан."])
            }
        }

        // Создаем родительскую директорию назначения если не существует
        let parentDir = destURL.deletingLastPathComponent()
        try fm.createDirectory(at: parentDir, withIntermediateDirectories: true)

        // Пишем во временный файл рядом и заменяем целевой только после успешного завершения:
        // при ошибке существующий архив остаётся нетронутым
        let tempURL = parentDir.appendingPathComponent(".\(destURL.lastPathComponent).\(UUID().uuidString).partial")
        let tempPath = tempURL.path

        do {
            try await runArchiveProcess(sources: sources, tempPath: tempPath, format: format)
        } catch {
            try? fm.removeItem(at: tempURL)
            throw error
        }

        do {
            if fm.fileExists(atPath: destURL.path) {
                _ = try fm.replaceItemAt(destURL, withItemAt: tempURL)
            } else {
                try fm.moveItem(at: tempURL, to: destURL)
            }
        } catch {
            try? fm.removeItem(at: tempURL)
            throw error
        }
    }

    private func runArchiveProcess(sources: [String], tempPath: String, format: ArchiveFormat) async throws {
        return try await withCheckedThrowingContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                let process = Process()
                let errPipe = Pipe()
                process.standardError = errPipe

                switch format {
                case .zip:
                    // Если один файл/каталог: используем Apple ditto (нативный формат архивов macOS с сохранением метаданных)
                    if sources.count == 1 {
                        let isDir = (try? FileManager.default.attributesOfItem(atPath: sources[0])[.type] as? FileAttributeType) == .typeDirectory
                        process.executableURL = URL(fileURLWithPath: "/usr/bin/ditto")
                        if isDir {
                            process.arguments = ["-c", "-k", "--sequesterRsrc", "--keepParent", sources[0], tempPath]
                        } else {
                            process.arguments = ["-c", "-k", "--sequesterRsrc", sources[0], tempPath]
                        }
                    } else {
                        // Для нескольких источников: используем /usr/bin/zip
                        process.executableURL = URL(fileURLWithPath: "/usr/bin/zip")
                        let firstDir = URL(fileURLWithPath: sources[0]).deletingLastPathComponent()
                        process.currentDirectoryURL = firstDir

                        var args = ["-r", "-q", tempPath]
                        for src in sources {
                            args.append(URL(fileURLWithPath: src).lastPathComponent)
                        }
                        process.arguments = args
                    }

                case .tarGz:
                    process.executableURL = URL(fileURLWithPath: "/usr/bin/tar")
                    let firstDir = URL(fileURLWithPath: sources[0]).deletingLastPathComponent()
                    process.currentDirectoryURL = firstDir
                    var args = ["-czf", tempPath]
                    for src in sources {
                        args.append(URL(fileURLWithPath: src).lastPathComponent)
                    }
                    process.arguments = args

                case .tar:
                    process.executableURL = URL(fileURLWithPath: "/usr/bin/tar")
                    let firstDir = URL(fileURLWithPath: sources[0]).deletingLastPathComponent()
                    process.currentDirectoryURL = firstDir
                    var args = ["-cf", tempPath]
                    for src in sources {
                        args.append(URL(fileURLWithPath: src).lastPathComponent)
                    }
                    process.arguments = args
                }

                do {
                    try process.run()
                    // stderr читаем ДО waitUntilExit: иначе при выводе >64 КБ процесс блокируется на записи в pipe (дедлок)
                    let errData = errPipe.fileHandleForReading.readDataToEndOfFile()
                    process.waitUntilExit()

                    if process.terminationStatus == 0 {
                        continuation.resume()
                    } else {
                        let errMsg = String(data: errData, encoding: .utf8) ?? "Ошибка процесса архивирования"
                        continuation.resume(throwing: NSError(
                            domain: "ArchiveService",
                            code: Int(process.terminationStatus),
                            userInfo: [NSLocalizedDescriptionKey: "Ошибка создания архива: \(errMsg)"]
                        ))
                    }
                } catch {
                    continuation.resume(throwing: error)
                }
            }
        }
    }
}
