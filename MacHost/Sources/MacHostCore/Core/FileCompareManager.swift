import Foundation

public struct CompareTarget: Equatable, Sendable {
    public let fileItem: FileItem
    public let canonicalPath: String
    public let isRemote: Bool
    public var localResolvedURL: URL?
    
    public init(fileItem: FileItem, canonicalPath: String, isRemote: Bool, localResolvedURL: URL? = nil) {
        self.fileItem = fileItem
        self.canonicalPath = canonicalPath
        self.isRemote = isRemote
        self.localResolvedURL = localResolvedURL
    }
}

public enum TargetError: Error, Equatable, Sendable {
    case noSelection(String)
    case multipleSelected(String)
    case isDirectory(String)
    case notRegularFile(String)
    case fileTooLarge(String)
    case notText(String)
    case noAccess(String)
    
    public var message: String {
        switch self {
        case .noSelection(let msg),
             .multipleSelected(let msg),
             .isDirectory(let msg),
             .notRegularFile(let msg),
             .fileTooLarge(let msg),
             .notText(let msg),
             .noAccess(let msg):
            return msg
        }
    }
}

public enum CompareState: Equatable, Sendable {
    case ready(left: CompareTarget, right: CompareTarget)
    case noLeftFile(reason: String)
    case noRightFile(reason: String)
    case leftInvalid(reason: String)
    case rightInvalid(reason: String)
    case sameFile
    case checking
    
    public var isReady: Bool {
        if case .ready = self { return true }
        return false
    }
    
    public var tooltip: String {
        switch self {
        case .ready:
            return "Сравнить файлы (по содержимому)"
        case .noLeftFile(let reason):
            return reason
        case .noRightFile(let reason):
            return reason
        case .leftInvalid(let reason):
            return "Слева: \(reason)"
        case .rightInvalid(let reason):
            return "Справа: \(reason)"
        case .sameFile:
            return "Это один и тот же файл"
        case .checking:
            return "Проверка файлов..."
        }
    }
}

public final class FileCompareManager: @unchecked Sendable {
    public static let shared = FileCompareManager()
    
    private let fileManager = FileManager.default
    private let baseTempDir: URL
    private var activeSessionUUID: UUID?
    private var downloadedFiles: [URL] = []
    private let lock = NSLock()
    
    public init() {
        let tempRoot = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
        self.baseTempDir = tempRoot.appendingPathComponent("MacDroidCommander_Diff", isDirectory: true)
        cleanupStaleTempDirectories()
    }
    
    /// Очистка остатков от предыдущих сеансов при старте приложения (FR-27)
    public func cleanupStaleTempDirectories() {
        try? fileManager.removeItem(at: baseTempDir)
        try? fileManager.createDirectory(at: baseTempDir, withIntermediateDirectories: true)
    }
    
    /// Разрешение цели для одной панели согласно правилам п. 4 ТЗ
    public static func resolveCompareTarget(
        side: PaneSide,
        items: [FileItem],
        selection: Set<String>,
        cursorItemId: String?
    ) -> Result<CompareTarget, TargetError> {
        let sideName = (side == .left) ? "в левой панели" : "в правой панели"
        
        // 1. Проверяем количество отметок (FR-6)
        var targetItem: FileItem?
        
        if selection.count == 1 {
            // Ровно 1 отметка -> Приоритет у отметки, курсор игнорируется (Правило 2)
            if let selectedId = selection.first {
                let norm = selectedId.precomposedStringWithCanonicalMapping
                targetItem = items.first(where: {
                    $0.id == selectedId || $0.path == selectedId ||
                    $0.id.precomposedStringWithCanonicalMapping == norm ||
                    $0.path.precomposedStringWithCanonicalMapping == norm
                })
            }
        } else if selection.count > 1 {
            // >= 2 отметок -> Отказ «Отметьте только один файл в левой/правой панели» (Правило 3)
            return .failure(.multipleSelected("Отметьте только один файл \(sideName)"))
        } else {
            // В панели 0 отметок -> Цель = элемент под курсором (Правило 1)
            if let cId = cursorItemId {
                let norm = cId.precomposedStringWithCanonicalMapping
                targetItem = items.first(where: {
                    $0.id == cId || $0.path == cId ||
                    $0.id.precomposedStringWithCanonicalMapping == norm ||
                    $0.path.precomposedStringWithCanonicalMapping == norm
                })
            }
        }
        
        // Дополнительный fallback: если отметка и курсор не установлены, проверяем текущую строку в NSTableView
        if targetItem == nil {
            let tv = (side == .left) ? TableDoubleClickHandler.HandlerView.leftTableView : TableDoubleClickHandler.HandlerView.rightTableView
            if let tv = tv, tv.selectedRow >= 0 && tv.selectedRow < items.count {
                targetItem = items[tv.selectedRow]
            }
        }
        
        guard let item = targetItem else {
            return .failure(.noSelection("Выберите файл \(sideName)"))
        }
        
        // Правило 4: Папка, .., пустая панель -> «Выберите файл»
        if item.isDirectory || item.name == ".." || item.name == "." {
            return .failure(.isDirectory("Это папка, выберите файл \(sideName)"))
        }
        
        // Правило 5: Не обычный файл (FIFO, socket, устройство)
        if !item.source.isRemote {
            var isDir: ObjCBool = false
            if !FileManager.default.fileExists(atPath: item.path, isDirectory: &isDir) {
                return .failure(.noAccess("Файл недоступен \(sideName)"))
            }
            if isDir.boolValue {
                return .failure(.isDirectory("Это папка, выберите файл \(sideName)"))
            }
            
            var statBuf = stat()
            if stat(item.path, &statBuf) == 0 {
                let fileMode = statBuf.st_mode
                let isRegular = (fileMode & S_IFMT) == S_IFREG
                let isSymlink = (fileMode & S_IFMT) == S_IFLNK
                if !isRegular && !isSymlink {
                    return .failure(.notRegularFile("Не обычный файл \(sideName)"))
                }
            }
        }
        
        // Лимит по размеру (п. 7)
        if item.size > FileEncodingDetector.defaultMaxSizeBytes {
            return .failure(.fileTooLarge("Файл больше 10 МБ \(sideName)"))
        }
        
        // Получаем канонический путь с учетом realpath и симлинков (FR-7, FR-8)
        let canonical: String
        if !item.source.isRemote {
            let real = resolveRealpath(item.path)
            canonical = real.lowercased() // macOS по умолчанию регистронезависима (FR-8)
        } else {
            canonical = "remote:" + item.path.lowercased()
        }
        
        let target = CompareTarget(
            fileItem: item,
            canonicalPath: canonical,
            isRemote: item.source.isRemote,
            localResolvedURL: item.source.isRemote ? nil : URL(fileURLWithPath: item.path)
        )
        return .success(target)
    }
    
    /// Разрешение реального пути (realpath) для симлинков
    public static func resolveRealpath(_ path: String) -> String {
        var resolved = [CChar](repeating: 0, count: Int(PATH_MAX))
        if realpath(path, &resolved) != nil {
            return String(cString: resolved)
        }
        return (path as NSString).standardizingPath
    }
    
    /// Синхронное быстрое вычисление состояния целей (п. 5, п. 6 FR-13)
    public static func computeFastCompareState(
        leftItems: [FileItem],
        leftSelection: Set<String>,
        leftCursorId: String?,
        rightItems: [FileItem],
        rightSelection: Set<String>,
        rightCursorId: String?
    ) -> CompareState {
        let leftRes = resolveCompareTarget(
            side: .left,
            items: leftItems,
            selection: leftSelection,
            cursorItemId: leftCursorId
        )
        let rightRes = resolveCompareTarget(
            side: .right,
            items: rightItems,
            selection: rightSelection,
            cursorItemId: rightCursorId
        )
        
        switch (leftRes, rightRes) {
        case (.failure(let errLeft), .failure):
            switch errLeft {
            case .noSelection(let m): return .noLeftFile(reason: m)
            default: return .leftInvalid(reason: errLeft.message)
            }
            
        case (.failure(let errLeft), .success):
            switch errLeft {
            case .noSelection(let m): return .noLeftFile(reason: m)
            default: return .leftInvalid(reason: errLeft.message)
            }
            
        case (.success, .failure(let errRight)):
            switch errRight {
            case .noSelection(let m): return .noRightFile(reason: m)
            default: return .rightInvalid(reason: errRight.message)
            }
            
        case (.success(let leftTarget), .success(let rightTarget)):
            // Проверка на SameFile (п. 5, FR-10)
            if leftTarget.canonicalPath == rightTarget.canonicalPath {
                return .sameFile
            }
            return .ready(left: leftTarget, right: rightTarget)
        }
    }
    
    // MARK: - Подготовка удаленных файлов (п. 9)
    
    /// Загрузка удаленного файла во временный каталог (FR-23, FR-24, FR-26)
    public func prepareTargetForComparison(
        target: CompareTarget,
        side: PaneSide,
        downloader: @Sendable (String, URL) async throws -> Void
    ) async throws -> URL {
        if !target.isRemote, let localURL = target.localResolvedURL {
            return localURL // FR-29: Для локальных файлов копия не создается
        }
        
        let ext = URL(fileURLWithPath: target.fileItem.name).pathExtension
        let targetTempURL = allocateTempTargetURL(side: side, ext: ext)
        
        try await downloader(target.fileItem.path, targetTempURL)
        
        // Помечаем read-only (FR-26)
        try? fileManager.setAttributes([.posixPermissions: 0o444], ofItemAtPath: targetTempURL.path)
        
        recordDownloadedFile(targetTempURL)
        return targetTempURL
    }
    
    private func allocateTempTargetURL(side: PaneSide, ext: String) -> URL {
        lock.lock()
        defer { lock.unlock() }
        if activeSessionUUID == nil {
            activeSessionUUID = UUID()
        }
        let session = activeSessionUUID!
        let sideSubdir = (side == .left) ? "left" : "right"
        let sideDir = baseTempDir.appendingPathComponent("\(session.uuidString)/\(sideSubdir)", isDirectory: true)
        try? fileManager.createDirectory(at: sideDir, withIntermediateDirectories: true)
        
        let uniqueName = ext.isEmpty ? UUID().uuidString : "\(UUID().uuidString).\(ext)"
        return sideDir.appendingPathComponent(uniqueName)
    }
    
    private func recordDownloadedFile(_ url: URL) {
        lock.lock()
        defer { lock.unlock() }
        downloadedFiles.append(url)
    }
    
    /// Очистка файлов текущего сеанса сравнения (FR-27)
    public func closeSession() {
        lock.lock()
        defer { lock.unlock() }
        
        if let session = activeSessionUUID {
            let sessionDir = baseTempDir.appendingPathComponent(session.uuidString)
            try? fileManager.removeItem(at: sessionDir)
            activeSessionUUID = nil
        }
        downloadedFiles.removeAll()
    }
}
