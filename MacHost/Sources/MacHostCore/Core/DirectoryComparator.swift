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
    
    /// Metadata-only classification. Matching files remain unverified and are
    /// deliberately marked different; use the digest overload to prove equality.
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
                    different.insert(name)
                } else {
                    // Size and mtime cannot establish content equality.
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

    /// Legacy metadata-only traversal. It cannot mark matching files identical.
    @available(*, deprecated, message: "Use the contentDigest overload for verified comparison")
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

    /// Recursively compares common directories and hashes same-sized files.
    /// Modification dates never establish equality.
    public func compare(
        left: [FileItem], right: [FileItem],
        listDirectory: @Sendable (FileItem) async throws -> [FileItem],
        contentDigest: @Sendable (FileItem) async throws -> String
    ) async throws -> DirectoryComparisonResult {
        try Task.checkCancellation()
        var onlyLeft = Set<String>()
        var onlyRight = Set<String>()
        var different = Set<String>()
        var identical = Set<String>()
        let leftMap = Dictionary(left.map { ($0.name, $0) }, uniquingKeysWith: { first, _ in first })
        let rightMap = Dictionary(right.map { ($0.name, $0) }, uniquingKeysWith: { first, _ in first })

        for (name, leftItem) in leftMap {
            try Task.checkCancellation()
            guard let rightItem = rightMap[name] else {
                onlyLeft.insert(name)
                continue
            }
            guard leftItem.isDirectory == rightItem.isDirectory else {
                different.insert(name)
                continue
            }
            if leftItem.isDirectory {
                if try await directoriesMatchExact(leftItem, rightItem,
                                                   listDirectory: listDirectory,
                                                   contentDigest: contentDigest) {
                    identical.insert(name)
                } else {
                    different.insert(name)
                }
            } else if leftItem.size != rightItem.size {
                different.insert(name)
            } else {
                let leftDigest = try await contentDigest(leftItem)
                try Task.checkCancellation()
                let rightDigest = try await contentDigest(rightItem)
                if leftDigest == rightDigest {
                    identical.insert(name)
                } else {
                    different.insert(name)
                }
            }
        }
        for name in rightMap.keys where leftMap[name] == nil {
            onlyRight.insert(name)
        }
        try Task.checkCancellation()
        return DirectoryComparisonResult(onlyLeft: onlyLeft, onlyRight: onlyRight,
                                         different: different, identical: identical)
    }

    private func directoriesMatchExact(
        _ left: FileItem, _ right: FileItem,
        listDirectory: @Sendable (FileItem) async throws -> [FileItem],
        contentDigest: @Sendable (FileItem) async throws -> String
    ) async throws -> Bool {
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
            let leftMap = Dictionary(leftChildren.map { ($0.name, $0) }, uniquingKeysWith: { first, _ in first })
            let rightMap = Dictionary(rightChildren.map { ($0.name, $0) }, uniquingKeysWith: { first, _ in first })
            guard leftMap.count == rightMap.count,
                  leftMap.keys.allSatisfy({ rightMap[$0] != nil }) else { return false }

            for (name, child) in leftMap {
                try Task.checkCancellation()
                guard let other = rightMap[name], child.isDirectory == other.isDirectory else { return false }
                if child.isDirectory {
                    pending.append((child, other, leftAncestors.union([leftKey]),
                                    rightAncestors.union([rightKey]), depth + 1))
                } else {
                    guard child.size == other.size else { return false }
                    let leftDigest = try await contentDigest(child)
                    try Task.checkCancellation()
                    let rightDigest = try await contentDigest(other)
                    guard leftDigest == rightDigest else { return false }
                }
            }
        }
        return true
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
