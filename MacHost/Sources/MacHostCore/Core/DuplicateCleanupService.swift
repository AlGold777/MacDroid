import Foundation

/// Revalidates candidates immediately before moving selected duplicate copies to trash.
public struct DuplicateCleanupService: Sendable {
    private let digest: @Sendable (FileItem) async throws -> String
    private let trash: @Sendable (FileItem) async throws -> Void

    public init(contentDigest: @escaping @Sendable (FileItem) async throws -> String,
                moveToTrash: @escaping @Sendable (FileItem) async throws -> Void) {
        digest = contentDigest
        trash = moveToTrash
    }

    public static func itemID(_ item: FileItem) -> String { "\(item.source.rawValue):\(item.path)" }

    public func removeSelected(groups: [DuplicateGroup], selectedIDs: Set<String>) async throws {
        var candidates: [(item: FileItem, keeper: FileItem, digest: String)] = []
        var known = Set<String>()
        for group in groups {
            let ids = group.items.map(Self.itemID)
            guard Set(ids).count == ids.count, known.isDisjoint(with: ids) else {
                throw failure("Повторяющиеся записи в результатах. Запустите поиск заново.")
            }
            known.formUnion(ids)
            let selected = group.items.filter { selectedIDs.contains(Self.itemID($0)) }
            guard !selected.isEmpty else { continue }
            guard let keeper = group.items.first(where: { !selectedIDs.contains(Self.itemID($0)) }) else {
                throw failure("В каждой группе необходимо оставить хотя бы одну копию.")
            }
            for item in [keeper] + selected {
                try Task.checkCancellation()
                guard try await digest(item) == group.digest else {
                    throw failure("Содержимое изменилось: \(item.path). Запустите поиск заново.")
                }
            }
            candidates.append(contentsOf: selected.map { ($0, keeper, group.digest) })
        }
        guard selectedIDs.isSubset(of: known) else { throw failure("Результаты устарели. Запустите поиск заново.") }
        for candidate in candidates {
            try Task.checkCancellation()
            // A long batch must not rely on a hash calculated before earlier moves.
            guard try await digest(candidate.keeper) == candidate.digest,
                  try await digest(candidate.item) == candidate.digest else {
                throw failure("Содержимое изменилось. Запустите поиск заново.")
            }
            try await trash(candidate.item)
        }
    }

    private func failure(_ message: String) -> NSError {
        NSError(domain: "DuplicateCleanup", code: 1, userInfo: [NSLocalizedDescriptionKey: message])
    }
}
