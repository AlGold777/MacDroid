import Foundation

public struct DuplicateGroup: Identifiable, Sendable, Hashable {
    public let id: String
    public let digest: String
    public let size: UInt64
    public let items: [FileItem]

    public init(digest: String, size: UInt64, items: [FileItem]) {
        self.digest = digest
        self.size = size
        self.items = items
        self.id = "\(size):\(digest)"
    }
}

public enum DuplicateFinderError: LocalizedError, Sendable {
    case unsafeTraversal(String)

    public var errorDescription: String? {
        switch self {
        case .unsafeTraversal(let path):
            return "Циклическая ссылка или глубина обхода больше 256 уровней: \(path)"
        }
    }
}

/// Finds byte-identical files under arbitrary local/remote roots.
public struct DuplicateFinder: Sendable {
    private let listDirectory: @Sendable (FileItem) async throws -> [FileItem]
    private let contentDigest: @Sendable (FileItem) async throws -> String
    private let progress: @Sendable (Int) -> Void

    public init(
        listDirectory: @escaping @Sendable (FileItem) async throws -> [FileItem],
        contentDigest: @escaping @Sendable (FileItem) async throws -> String,
        progress: @escaping @Sendable (Int) -> Void = { _ in }
    ) {
        self.listDirectory = listDirectory
        self.contentDigest = contentDigest
        self.progress = progress
    }

    public func findDuplicates(roots: [FileItem]) async throws -> [DuplicateGroup] {
        var pending: [(FileItem, Set<String>, Int)] = []
        var filesBySize: [UInt64: [FileItem]] = [:]
        var visitedDirectories = Set<String>()
        var visitedFiles = Set<String>()
        var completedFiles = 0

        func appendFile(_ item: FileItem) {
            let key = itemKey(item)
            guard visitedFiles.insert(key).inserted else { return }
            filesBySize[item.size, default: []].append(item)
            completedFiles += 1
            progress(completedFiles)
        }

        for root in roots {
            try Task.checkCancellation()
            guard !isInsideTrash(root) else { continue }
            if root.isDirectory {
                pending.append((root, [], 0))
            } else {
                appendFile(root)
            }
        }

        while let (directory, ancestors, depth) = pending.popLast() {
            try Task.checkCancellation()
            guard !isInsideTrash(directory) else { continue }
            let key = directoryKey(directory)
            guard depth < 256, !ancestors.contains(key) else {
                throw DuplicateFinderError.unsafeTraversal(directory.path)
            }
            guard visitedDirectories.insert(key).inserted else { continue }

            let children = try await listDirectory(directory)
            try Task.checkCancellation()
            for child in children {
                try Task.checkCancellation()
                guard !isInsideTrash(child), child.name != PhoneTrashService.directoryName else { continue }
                if child.isDirectory {
                    pending.append((child, ancestors.union([key]), depth + 1))
                } else {
                    appendFile(child)
                }
            }
        }

        var groupItems: [String: (size: UInt64, digest: String, items: [FileItem])] = [:]
        let sizeBuckets = filesBySize.keys.sorted()
        for size in sizeBuckets {
            guard let candidates = filesBySize[size], candidates.count > 1 else { continue }
            for item in candidates {
                try Task.checkCancellation()
                let rawDigest = try await contentDigest(item)
                let digest = rawDigest.lowercased()
                try Task.checkCancellation()
                let key = "\(size):\(digest)"
                if groupItems[key] == nil {
                    groupItems[key] = (size, digest, [item])
                } else {
                    groupItems[key]?.items.append(item)
                }
            }
        }

        try Task.checkCancellation()
        return groupItems.values
            .filter { $0.items.count > 1 }
            .map { DuplicateGroup(digest: $0.digest, size: $0.size, items: $0.items.sorted(by: itemOrder)) }
            .sorted { lhs, rhs in
                if lhs.size != rhs.size { return lhs.size < rhs.size }
                return lhs.digest < rhs.digest
            }
    }

    private func directoryKey(_ item: FileItem) -> String {
        "\(item.source.rawValue):\(canonicalPath(item.path, source: item.source))"
    }

    private func itemKey(_ item: FileItem) -> String {
        "\(item.source.rawValue):\(canonicalPath(item.path, source: item.source))"
    }

    private func canonicalPath(_ path: String, source: FileSource) -> String {
        let url = URL(fileURLWithPath: path)
        if source == .localMac {
            return url.resolvingSymlinksInPath().standardizedFileURL.path.precomposedStringWithCanonicalMapping
        }
        let standardized = url.standardizedFileURL.path
        let aliases = ["/sdcard", "/emulated/0", "/storage/self/primary", "/mnt/sdcard"]
        for alias in aliases where standardized == alias || standardized.hasPrefix(alias + "/") {
            return ("/storage/emulated/0" + standardized.dropFirst(alias.count))
                .precomposedStringWithCanonicalMapping
        }
        return standardized.precomposedStringWithCanonicalMapping
    }

    private func isInsideTrash(_ item: FileItem) -> Bool {
        isInsideTrashPath(item.path) || isInsideTrashPath(canonicalPath(item.path, source: item.source))
    }

    private func isInsideTrashPath(_ path: String) -> Bool {
        path.split(separator: "/").contains { String($0) == PhoneTrashService.directoryName }
    }

    private func itemOrder(_ lhs: FileItem, _ rhs: FileItem) -> Bool {
        if lhs.source.rawValue != rhs.source.rawValue { return lhs.source.rawValue < rhs.source.rawValue }
        return lhs.path < rhs.path
    }
}
