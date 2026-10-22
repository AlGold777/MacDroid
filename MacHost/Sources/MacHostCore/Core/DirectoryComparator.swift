import Foundation

public struct PanelTab: Identifiable, Sendable, Codable {
    public let id: UUID
    public var title: String
    public var path: String
    public var source: FileSource
    public var isPinned: Bool
    
    public init(id: UUID = UUID(), title: String, path: String, source: FileSource, isPinned: Bool = false) {
        self.id = id
        self.title = title
        self.path = path.precomposedStringWithCanonicalMapping
        self.source = source
        self.isPinned = isPinned
    }
    
    private enum CodingKeys: String, CodingKey {
        case id, title, path, source, isPinned
    }
    
    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.id = try container.decode(UUID.self, forKey: .id)
        self.title = try container.decode(String.self, forKey: .title)
        self.path = try container.decode(String.self, forKey: .path).precomposedStringWithCanonicalMapping
        self.source = try container.decode(FileSource.self, forKey: .source)
        self.isPinned = try container.decodeIfPresent(Bool.self, forKey: .isPinned) ?? false
    }
}

public enum TabImportMode: Sendable {
    case replace
    case append
}

public struct TabsExportData: Codable, Sendable {
    public var version: Int
    public var leftTabs: [PanelTab]
    public var rightTabs: [PanelTab]
    public var leftActiveTabId: UUID?
    public var rightActiveTabId: UUID?
    
    public init(
        leftTabs: [PanelTab],
        rightTabs: [PanelTab],
        leftActiveTabId: UUID? = nil,
        rightActiveTabId: UUID? = nil,
        version: Int = 1
    ) {
        self.version = version
        self.leftTabs = leftTabs
        self.rightTabs = rightTabs
        self.leftActiveTabId = leftActiveTabId
        self.rightActiveTabId = rightActiveTabId
    }
}

public struct DirectoryComparisonResult: Sendable {
    public let onlyLeft: Set<String>
    public let onlyRight: Set<String>
    public let different: Set<String>
    public let identical: Set<String>
    
    public init(
        onlyLeft: Set<String> = [],
        onlyRight: Set<String> = [],
        different: Set<String> = [],
        identical: Set<String> = []
    ) {
        self.onlyLeft = onlyLeft
        self.onlyRight = onlyRight
        self.different = different
        self.identical = identical
    }
}

public final class DirectoryComparator: Sendable {
    public init() {}
    
    public func compare(left: [FileItem], right: [FileItem]) -> DirectoryComparisonResult {
        let leftMap = Dictionary(left.map { ($0.name, $0) }, uniquingKeysWith: { a, _ in a })
        let rightMap = Dictionary(right.map { ($0.name, $0) }, uniquingKeysWith: { a, _ in a })
        
        var onlyLeft = Set<String>()
        var onlyRight = Set<String>()
        var different = Set<String>()
        var identical = Set<String>()
        
        for (name, leftItem) in leftMap {
            if let rightItem = rightMap[name] {
                if leftItem.isDirectory && rightItem.isDirectory {
                    identical.insert(name)
                } else if !leftItem.isDirectory && !rightItem.isDirectory {
                    if leftItem.size == rightItem.size && abs(leftItem.mtime - rightItem.mtime) < 2 {
                        identical.insert(name)
                    } else {
                        different.insert(name)
                    }
                } else {
                    different.insert(name)
                }
            } else {
                onlyLeft.insert(name)
            }
        }
        
        for (name, _) in rightMap {
            if leftMap[name] == nil {
                onlyRight.insert(name)
            }
        }
        
        return DirectoryComparisonResult(
            onlyLeft: onlyLeft,
            onlyRight: onlyRight,
            different: different,
            identical: identical
        )
    }
}
