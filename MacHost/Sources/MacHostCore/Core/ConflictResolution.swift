import Foundation

public enum ConflictResolutionStrategy: String, CaseIterable, Identifiable, Sendable {
    case overwrite          = "Заменить"
    case overwriteIfNewer   = "Заменить, если новее"
    case skip               = "Пропустить"
    case skipIfIdentical    = "Пропустить идентичные"
    case autoRename         = "Автоматически переименовать (-1)"
    case customRename       = "Переименовать"
    
    public var id: String { self.rawValue }
}

public struct ConflictResolutionResult: Sendable {
    public let action: ConflictResolutionStrategy
    public let applyToAll: Bool
    public let customName: String?
    
    public init(action: ConflictResolutionStrategy, applyToAll: Bool, customName: String? = nil) {
        self.action = action
        self.applyToAll = applyToAll
        self.customName = customName
    }
}

public struct ConflictContext: Identifiable, Sendable {
    public let id: String
    public let sourceItem: FileItem
    public let targetItem: FileItem
    public let totalFilesCount: Int
    
    public init(sourceItem: FileItem, targetItem: FileItem, totalFilesCount: Int = 1) {
        self.id = UUID().uuidString
        self.sourceItem = sourceItem
        self.targetItem = targetItem
        self.totalFilesCount = totalFilesCount
    }
    
    public var canSkip: Bool {
        return totalFilesCount > 1
    }
    
    public var isIdentical: Bool {
        return sourceItem.size == targetItem.size &&
               abs(sourceItem.mtime - targetItem.mtime) < 2.0 // точность в пределах 2 сек
    }
    
    public var isSourceNewer: Bool {
        return sourceItem.mtime > targetItem.mtime
    }
}

/// Генерация имени с суффиксом -n (например, example.txt -> example-1.txt, example-1.txt -> example-2.txt)
public func generateAutoRename(filename: String) -> String {
    let lastDot = filename.lastIndex(of: ".")
    let base: String
    let ext: String
    
    if let lastDot = lastDot, lastDot > filename.startIndex {
        base = String(filename[..<lastDot])
        ext = String(filename[lastDot...])
    } else {
        base = filename
        ext = ""
    }
    
    if let range = base.range(of: #"-(\d+)$"#, options: .regularExpression) {
        let numPart = base[range].dropFirst()
        if let num = Int(numPart) {
            let prefix = String(base[..<range.lowerBound])
            return "\(prefix)-\(num + 1)\(ext)"
        }
    }
    
    return "\(base)-1\(ext)"
}
