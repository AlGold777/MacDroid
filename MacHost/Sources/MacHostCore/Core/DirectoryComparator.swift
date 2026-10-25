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
                    // Без чтения содержимого равенство каталогов не установлено.
                    different.insert(name)
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

    /// Сохраняет результаты на уровне панелей, проверяя каждую общую папку до листьев.
    public func compare(
        left: [FileItem], right: [FileItem],
        listDirectory: @Sendable (FileItem) async throws -> [FileItem]
    ) async throws -> DirectoryComparisonResult {
        try Task.checkCancellation()
        let base = compare(left: left, right: right)
        let rightMap = Dictionary(right.map { ($0.name, $0) }, uniquingKeysWith: { a, _ in a })
        var different = base.different
        var identical = base.identical
        for item in left where item.isDirectory {
            guard let other = rightMap[item.name], other.isDirectory else { continue }
            if try await directoriesMatch(item, other, listDirectory: listDirectory) {
                different.remove(item.name)
                identical.insert(item.name)
            }
        }
        try Task.checkCancellation()
        return DirectoryComparisonResult(onlyLeft: base.onlyLeft, onlyRight: base.onlyRight,
                                         different: different, identical: identical)
    }

    private func directoriesMatch(
        _ left: FileItem, _ right: FileItem,
        listDirectory: @Sendable (FileItem) async throws -> [FileItem]
    ) async throws -> Bool {
        // Итеративный обход не расходует стек Swift. Наборы предков выявляют циклы
        // локальных ссылок; лимит глубины ограничивает также неизвестные remote-циклы.
        var pending: [(FileItem, FileItem, Set<String>, Set<String>, Int)] = [(left, right, [], [], 0)]
        while let (lhs, rhs, leftAncestors, rightAncestors, depth) = pending.popLast() {
            try Task.checkCancellation()
            let leftKey = directoryKey(lhs)
            let rightKey = directoryKey(rhs)
            guard depth < 256, !leftAncestors.contains(leftKey), !rightAncestors.contains(rightKey) else {
                throw DirectoryComparisonError.unsafeTraversal(lhs.path)
            }
            let leftChildren = try await listDirectory(lhs)
            try Task.checkCancellation()
            let rightChildren = try await listDirectory(rhs)
            try Task.checkCancellation()
            let summary = compare(left: leftChildren, right: rightChildren)
            guard summary.onlyLeft.isEmpty, summary.onlyRight.isEmpty else { return false }
            let rightMap = Dictionary(rightChildren.map { ($0.name, $0) }, uniquingKeysWith: { a, _ in a })
            for child in leftChildren {
                guard let other = rightMap[child.name], child.isDirectory == other.isDirectory else { return false }
                if child.isDirectory {
                    pending.append((child, other, leftAncestors.union([leftKey]), rightAncestors.union([rightKey]), depth + 1))
                } else if summary.different.contains(child.name) {
                    return false
                }
            }
        }
        return true
    }

    private func directoryKey(_ item: FileItem) -> String {
        let path = item.source == .localMac
            ? URL(fileURLWithPath: item.path).resolvingSymlinksInPath().standardizedFileURL.path
            : item.path
        return "\(item.source.rawValue):\(path)"
    }
}

private enum DirectoryComparisonError: LocalizedError {
    case unsafeTraversal(String)

    var errorDescription: String? {
        switch self {
        case .unsafeTraversal(let path):
            return "Циклическая ссылка или слишком большая глубина каталогов: \(path)"
        }
    }
}
