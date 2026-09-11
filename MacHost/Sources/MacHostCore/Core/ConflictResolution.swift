import Foundation

public enum ConflictResolutionStrategy: String, CaseIterable, Identifiable, Sendable {
    case overwrite          = "Заменить"
    case overwriteIfNewer   = "Заменить, если новее"
    case skip               = "Пропустить"
    case skipIfIdentical    = "Пропустить идентичные"
    case autoRename         = "Автоматически переименовать (_1)"
    
    public var id: String { self.rawValue }
}

public struct ConflictContext: Identifiable, Sendable {
    public let id: String
    public let sourceItem: FileItem
    public let targetItem: FileItem
    
    public init(sourceItem: FileItem, targetItem: FileItem) {
        self.id = "\(sourceItem.id)->\(targetItem.id)"
        self.sourceItem = sourceItem
        self.targetItem = targetItem
    }
    
    public var isIdentical: Bool {
        return sourceItem.size == targetItem.size &&
               abs(sourceItem.mtime - targetItem.mtime) < 2.0 // точность в пределах 2 сек
    }
    
    public var isSourceNewer: Bool {
        return sourceItem.mtime > targetItem.mtime
    }
}
