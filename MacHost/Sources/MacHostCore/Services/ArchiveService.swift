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
    
    /// Создает архив из указанных путей (файлы и/или папки)
    public func createArchive(
        sources: [String],
        destinationPath: String,
        format: ArchiveFormat = .zip
    ) async throws {
        guard !sources.isEmpty else {
            throw NSError(domain: "ArchiveService", code: 1, userInfo: [NSLocalizedDescriptionKey: "Нет файлов для архивирования"])
        }
        
        let destURL = URL(fileURLWithPath: destinationPath)
        
        // Создаем родительскую директорию назначения если не существует
        let parentDir = destURL.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: parentDir, withIntermediateDirectories: true)
        
        // Если целевой архив уже существует — удаляем для перезаписи
        if FileManager.default.fileExists(atPath: destURL.path) {
            try? FileManager.default.removeItem(at: destURL)
        }
        
        return try await withCheckedThrowingContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                let process = Process()
                let errPipe = Pipe()
                process.standardError = errPipe
                
                switch format {
                case .zip:
                    // Если один файл/каталог: используем Apple ditto (нативный формат архивов macOS с сохранением метаданных)
                    if sources.count == 1 {
                        process.executableURL = URL(fileURLWithPath: "/usr/bin/ditto")
                        process.arguments = ["-c", "-k", "--sequesterRsrc", "--keepParent", sources[0], destinationPath]
                    } else {
                        // Для нескольких источников: используем /usr/bin/zip
                        process.executableURL = URL(fileURLWithPath: "/usr/bin/zip")
                        let firstDir = URL(fileURLWithPath: sources[0]).deletingLastPathComponent()
                        process.currentDirectoryURL = firstDir
                        
                        var args = ["-r", "-q", destinationPath]
                        for src in sources {
                            args.append(URL(fileURLWithPath: src).lastPathComponent)
                        }
                        process.arguments = args
                    }
                    
                case .tarGz:
                    process.executableURL = URL(fileURLWithPath: "/usr/bin/tar")
                    let firstDir = URL(fileURLWithPath: sources[0]).deletingLastPathComponent()
                    process.currentDirectoryURL = firstDir
                    var args = ["-czf", destinationPath]
                    for src in sources {
                        args.append(URL(fileURLWithPath: src).lastPathComponent)
                    }
                    process.arguments = args
                    
                case .tar:
                    process.executableURL = URL(fileURLWithPath: "/usr/bin/tar")
                    let firstDir = URL(fileURLWithPath: sources[0]).deletingLastPathComponent()
                    process.currentDirectoryURL = firstDir
                    var args = ["-cf", destinationPath]
                    for src in sources {
                        args.append(URL(fileURLWithPath: src).lastPathComponent)
                    }
                    process.arguments = args
                }
                
                do {
                    try process.run()
                    process.waitUntilExit()
                    
                    if process.terminationStatus == 0 {
                        continuation.resume()
                    } else {
                        let errData = errPipe.fileHandleForReading.readDataToEndOfFile()
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
