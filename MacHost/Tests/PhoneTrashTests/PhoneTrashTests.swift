import Darwin
import Foundation
import MacHostCore

private struct TestFailure: Error, CustomStringConvertible {
    let description: String
}

private func check(_ condition: Bool, _ message: String) throws {
    guard condition else { throw TestFailure(description: message) }
    print("  ✓ \(message)")
}

private enum FakeStorageError: Error {
    case injectedWriteFailure
    case injectedRenameFailure
    case missing(String)
    case exists(String)
    case notDirectory(String)
    case tooLarge(String)
}

private actor InMemoryPhoneTrashStorage: PhoneTrashStorage {
    private struct Node: Sendable {
        var isDirectory: Bool
        var data: Data
        var mtime: Double
    }

    private var nodes: [String: Node] = [:]
    private var events: [String] = []
    private var failNextWrite = false
    private var failNextRename = false

    init(volumes: [String]) {
        for volume in volumes {
            nodes[Self.normalized(volume)] = Node(isDirectory: true, data: Data(), mtime: 0)
        }
    }

    func seedDirectory(_ path: String) throws {
        let path = Self.normalized(path)
        guard nodes[path] == nil else { throw FakeStorageError.exists(path) }
        let parent = Self.parent(of: path)
        guard nodes[parent]?.isDirectory == true else { throw FakeStorageError.notDirectory(parent) }
        nodes[path] = Node(isDirectory: true, data: Data(), mtime: 0)
    }

    func seedFile(_ path: String, data: Data, mtime: Double = 1) throws {
        let path = Self.normalized(path)
        guard nodes[path] == nil else { throw FakeStorageError.exists(path) }
        let parent = Self.parent(of: path)
        guard nodes[parent]?.isDirectory == true else { throw FakeStorageError.notDirectory(parent) }
        nodes[path] = Node(isDirectory: false, data: data, mtime: mtime)
    }

    func failNextMetadataWrite() { failNextWrite = true }
    func failNextMove() { failNextRename = true }
    func operationLog() -> [String] { events }
    func contents(at path: String) -> Data? { nodes[Self.normalized(path)]?.data }

    func list(_ path: String) async throws -> [FileItem] {
        let directory = Self.normalized(path)
        events.append("list:\(directory)")
        guard nodes[directory]?.isDirectory == true else { throw FakeStorageError.notDirectory(directory) }
        return nodes.keys
            .filter { $0 != directory && Self.parent(of: $0) == directory }
            .sorted()
            .compactMap { childPath in
                guard let node = nodes[childPath] else { return nil }
                return FileItem(
                    id: childPath,
                    name: URL(fileURLWithPath: childPath).lastPathComponent,
                    path: childPath,
                    size: UInt64(node.data.count),
                    mtime: node.mtime,
                    isDirectory: node.isDirectory,
                    source: .remotePhone
                )
            }
    }

    func exists(_ path: String) async throws -> Bool {
        nodes[Self.normalized(path)] != nil
    }

    func mkdir(_ path: String) async throws {
        let path = Self.normalized(path)
        events.append("mkdir:\(path)")
        guard nodes[path] == nil else { throw FakeStorageError.exists(path) }
        let parent = Self.parent(of: path)
        guard nodes[parent]?.isDirectory == true else { throw FakeStorageError.notDirectory(parent) }
        nodes[path] = Node(isDirectory: true, data: Data(), mtime: 0)
    }

    func rename(_ source: String, _ destination: String) async throws {
        let source = Self.normalized(source)
        let destination = Self.normalized(destination)
        events.append("rename:\(source)->\(destination)")
        if failNextRename {
            failNextRename = false
            throw FakeStorageError.injectedRenameFailure
        }
        guard let sourceNode = nodes[source] else { throw FakeStorageError.missing(source) }
        guard nodes[destination] == nil else { throw FakeStorageError.exists(destination) }
        let parent = Self.parent(of: destination)
        guard nodes[parent]?.isDirectory == true else { throw FakeStorageError.notDirectory(parent) }
        let descendants = Array(nodes.keys).filter { $0 == source || $0.hasPrefix(source + "/") }
        for path in descendants {
            guard let node = nodes.removeValue(forKey: path) else { continue }
            let suffix = String(path.dropFirst(source.count))
            nodes[destination + suffix] = node
        }
        if sourceNode.isDirectory, nodes[destination] == nil {
            nodes[destination] = sourceNode
        }
    }

    func readSmallFile(_ path: String, maxBytes: Int) async throws -> Data {
        let path = Self.normalized(path)
        events.append("read:\(path)")
        guard let node = nodes[path], !node.isDirectory else { throw FakeStorageError.missing(path) }
        guard node.data.count <= maxBytes else { throw FakeStorageError.tooLarge(path) }
        return node.data
    }

    func writeExclusive(_ path: String, data: Data) async throws {
        let path = Self.normalized(path)
        events.append("write:\(path)")
        if failNextWrite {
            failNextWrite = false
            throw FakeStorageError.injectedWriteFailure
        }
        guard nodes[path] == nil else { throw FakeStorageError.exists(path) }
        let parent = Self.parent(of: path)
        guard nodes[parent]?.isDirectory == true else { throw FakeStorageError.notDirectory(parent) }
        nodes[path] = Node(isDirectory: false, data: data, mtime: 2)
    }

    func deleteFile(_ path: String) async throws {
        let path = Self.normalized(path)
        events.append("delete-file:\(path)")
        guard let node = nodes[path], !node.isDirectory else { throw FakeStorageError.missing(path) }
        nodes.removeValue(forKey: path)
    }

    func deletePermanent(_ path: String) async throws {
        let path = Self.normalized(path)
        events.append("delete:\(path)")
        guard nodes[path] != nil else { throw FakeStorageError.missing(path) }
        for child in Array(nodes.keys) where child == path || child.hasPrefix(path + "/") {
            nodes.removeValue(forKey: child)
        }
    }

    func removeEmptyDirectory(_ path: String) async throws {
        let path = Self.normalized(path)
        events.append("rmdir:\(path)")
        guard nodes[path]?.isDirectory == true else { throw FakeStorageError.notDirectory(path) }
        guard !nodes.keys.contains(where: { Self.parent(of: $0) == path }) else {
            throw FakeStorageError.exists(path)
        }
        nodes.removeValue(forKey: path)
    }

    private static func normalized(_ path: String) -> String {
        URL(fileURLWithPath: path).standardizedFileURL.path
    }

    private static func parent(of path: String) -> String {
        URL(fileURLWithPath: path).deletingLastPathComponent().path
    }
}

private struct PhoneTrashFixture {
    let storage: InMemoryPhoneTrashStorage
    let service: PhoneTrashService
    let volume = "/storage/emulated/0"

    init() {
        let storage = InMemoryPhoneTrashStorage(volumes: ["/storage/emulated/0", "/storage/1234-5678"])
        self.storage = storage
        self.service = PhoneTrashService(storage: storage)
    }
}

private func expectThrows(_ message: String, operation: () async throws -> Void) async throws {
    do {
        try await operation()
        throw TestFailure(description: "Expected failure: \(message)")
    } catch is TestFailure {
        throw TestFailure(description: "Expected failure: \(message)")
    } catch {
        print("  ✓ \(message)")
    }
}

private func runPhoneTrashTests() async throws {
    print("\n[PhoneTrashTests] Phone trash service")

    try check(
        try PhoneTrashService.volumeRoot(for: "/sdcard/DCIM/Camera/photo.jpg") == "/storage/emulated/0",
        "Legacy /sdcard alias resolves to the emulated storage volume"
    )
    try check(
        try PhoneTrashService.volumeRoot(for: "/storage/1234-5678/DCIM") == "/storage/1234-5678",
        "Secondary storage volume is recognized"
    )
    try await expectThrows("Unknown roots are rejected") {
        _ = try PhoneTrashService.volumeRoot(for: "/mnt/sdcard/DCIM/photo.jpg")
    }

    let fixture = PhoneTrashFixture()
    try await fixture.storage.seedFile("/storage/emulated/0/alias.txt", data: Data("alias".utf8))
    let aliasEntry = try await fixture.service.moveToTrash(at: "/sdcard/alias.txt")
    try check(aliasEntry.originalPath == "/storage/emulated/0/alias.txt",
              "Trash moves through /sdcard are stored under the canonical emulated volume path")

    try await fixture.storage.seedFile("/storage/1234-5678/volume.txt", data: Data("sd".utf8))
    let secondaryEntry = try await fixture.service.moveToTrash(at: "/storage/1234-5678/volume.txt")
    try check(try secondaryEntry.trashRoot == "/storage/1234-5678/.MacDroidTrash",
              "Trash storage remains isolated under the selected secondary volume")

    try await fixture.storage.seedDirectory("/storage/emulated/0/DCIM")
    try await fixture.storage.seedDirectory("/storage/emulated/0/DCIM/Camera")
    try await fixture.storage.seedDirectory("/storage/emulated/0/DCIM/Camera/旅行")
    try await fixture.storage.seedFile("/storage/emulated/0/DCIM/Camera/.nomedia", data: Data("hide".utf8))
    try await fixture.storage.seedFile("/storage/emulated/0/DCIM/Camera/旅行/写真.jpg", data: Data([1, 2, 3, 4]))
    let originalPayload = "/storage/emulated/0/DCIM/Camera"
    let firstEntry = try await fixture.service.moveToTrash(at: originalPayload)
    let firstEntryPath = try firstEntry.entryPath
    let firstMoveEvents = await fixture.storage.operationLog()
    try check(firstEntry.originalPath == originalPayload && firstEntry.isDirectory,
              "Directory trash records the original path and directory type")
    let metadataWriteIndex = firstMoveEvents.firstIndex(of: "write:\(firstEntryPath)/info.json")
    let payloadRenameIndex = firstMoveEvents.firstIndex(of: "rename:\(originalPayload)->\(firstEntryPath)/payload")
    try check(metadataWriteIndex != nil && payloadRenameIndex != nil && metadataWriteIndex! < payloadRenameIndex!,
              "Metadata is written before the original payload is renamed")
    try check(try await fixture.storage.exists(originalPayload) == false,
              "Moved directory is no longer present at its original location")
    try check(try await fixture.storage.exists(firstEntryPath + "/payload") == true,
              "Directory payload is preserved inside the trash entry")
    try check(try await fixture.storage.exists(firstEntryPath + "/payload/.nomedia") == true,
              "Hidden files survive a directory move")
    try check(try await fixture.storage.exists(firstEntryPath + "/payload/旅行/写真.jpg") == true,
              "Nested Unicode paths survive a directory move")
    let firstListing = try await fixture.service.entries(volumePath: fixture.volume)
    try check(firstListing.map(\.id).contains(firstEntry.id),
              "A newly created trash entry appears in the listing")

    let reloadedService = PhoneTrashService(storage: fixture.storage)
    let recovered = try await reloadedService.entries(volumePath: fixture.volume)
    try check(recovered.contains(where: { $0.id == firstEntry.id && $0.originalPath == originalPayload }),
              "Trash metadata is recoverable after creating a new service instance")

    try await fixture.storage.seedDirectory("/storage/emulated/0/Pictures")
    try await fixture.storage.seedDirectory("/storage/emulated/0/Downloads")
    try await fixture.storage.seedFile("/storage/emulated/0/Pictures/same.jpg", data: Data("one".utf8))
    try await fixture.storage.seedFile("/storage/emulated/0/Downloads/same.jpg", data: Data("two".utf8))
    let pictureEntry = try await fixture.service.moveToTrash(at: "/storage/emulated/0/Pictures/same.jpg")
    let downloadEntry = try await fixture.service.moveToTrash(at: "/storage/emulated/0/Downloads/same.jpg")
    try check(pictureEntry.id != downloadEntry.id,
              "Files with the same name receive distinct trash identifiers")
    let entriesAfterCollisionMoves = try await fixture.service.entries(volumePath: fixture.volume)
    let collidingNames = entriesAfterCollisionMoves.filter {
        URL(fileURLWithPath: $0.originalPath).lastPathComponent == "same.jpg"
    }
    try check(collidingNames.count == 2,
              "Same-named files from different directories remain separate entries")

    try await fixture.storage.seedFile("/storage/emulated/0/metadata-failure.bin", data: Data("keep".utf8))
    await fixture.storage.failNextMetadataWrite()
    let operationsBeforeWriteFailure = await fixture.storage.operationLog().count
    try await expectThrows("Metadata-write failure prevents trash move") {
        _ = try await fixture.service.moveToTrash(at: "/storage/emulated/0/metadata-failure.bin")
    }
    try check(try await fixture.storage.exists("/storage/emulated/0/metadata-failure.bin"),
              "Metadata-write failure leaves the original file intact")
    let eventsAfterWriteFailure = await fixture.storage.operationLog().dropFirst(operationsBeforeWriteFailure)
    try check(!eventsAfterWriteFailure.contains(where: { $0.hasPrefix("rename:") }),
              "A payload rename is not attempted before metadata is safely written")
    let entriesAfterMetadataFailure = try await fixture.service.entries(volumePath: fixture.volume)
    try check(Set(entriesAfterMetadataFailure.map(\.id)) == Set([
        aliasEntry.id, firstEntry.id, pictureEntry.id, downloadEntry.id
    ]),
              "A metadata-write orphan without a payload does not block valid trash entries")

    try await fixture.storage.seedFile("/storage/emulated/0/before-move-failure.bin", data: Data("keep".utf8))
    let operationsBeforeCallbackFailure = await fixture.storage.operationLog().count
    try await expectThrows("A before-move validation failure prevents trash rename") {
        _ = try await fixture.service.moveToTrash(at: "/storage/emulated/0/before-move-failure.bin") {
            throw NSError(domain: "PhoneTrashTests", code: 1)
        }
    }
    try check(try await fixture.storage.exists("/storage/emulated/0/before-move-failure.bin"),
              "A before-move failure leaves the source file intact")
    let eventsAfterCallbackFailure = await fixture.storage.operationLog().dropFirst(operationsBeforeCallbackFailure)
    try check(!eventsAfterCallbackFailure.contains(where: { $0.hasPrefix("rename:") }),
              "PhoneTrashService does not rename when beforeMove validation fails")

    try await fixture.storage.seedFile("/storage/emulated/0/rename-failure.bin", data: Data("keep".utf8))
    await fixture.storage.failNextMove()
    try await expectThrows("Rename failure is surfaced without permanent-delete fallback") {
        _ = try await fixture.service.moveToTrash(at: "/storage/emulated/0/rename-failure.bin")
    }
    try check(try await fixture.storage.exists("/storage/emulated/0/rename-failure.bin"),
              "Rename failure leaves the original file intact")

    try await expectThrows("The storage volume root cannot be moved to trash") {
        _ = try await fixture.service.moveToTrash(at: fixture.volume)
    }
    try await expectThrows("The trash directory cannot be moved into itself") {
        _ = try await fixture.service.moveToTrash(at: fixture.volume + "/.MacDroidTrash")
    }
    try await expectThrows("Paths outside supported phone volumes cannot be trashed") {
        _ = try await fixture.service.moveToTrash(at: "/Users/test/document.txt")
    }
    try await expectThrows("Paths containing parent traversal are rejected") {
        _ = try await fixture.service.moveToTrash(at: "/storage/emulated/0/../Pictures/same.jpg")
    }

    try await fixture.storage.seedDirectory("/storage/emulated/0/Restore")
    try await fixture.storage.seedFile("/storage/emulated/0/Restore/report.txt", data: Data("trashed".utf8))
    let conflictEntry = try await fixture.service.moveToTrash(at: "/storage/emulated/0/Restore/report.txt")
    let conflictEntryPath = try conflictEntry.entryPath
    try await fixture.storage.seedFile("/storage/emulated/0/Restore/report.txt", data: Data("keep-both".utf8))
    try await expectThrows("Restore refuses to overwrite a conflicting file") {
        try await fixture.service.restore(conflictEntry)
    }
    try check(try await fixture.storage.exists(conflictEntryPath + "/payload"),
              "Restore conflict preserves the trashed payload")
    try check(await fixture.storage.contents(at: "/storage/emulated/0/Restore/report.txt") == Data("keep-both".utf8),
              "Restore conflict preserves the existing destination contents")

    try await fixture.storage.seedFile("/storage/emulated/0/Restore/success.txt", data: Data("restore me".utf8))
    let successfulRestore = try await fixture.service.moveToTrash(at: "/storage/emulated/0/Restore/success.txt")
    let successfulRestoreEntryPath = try successfulRestore.entryPath
    try await fixture.service.restore(successfulRestore)
    try check(await fixture.storage.contents(at: "/storage/emulated/0/Restore/success.txt") == Data("restore me".utf8),
              "Restore returns the payload to its original path")
    try check(try await fixture.storage.exists(successfulRestoreEntryPath) == false,
              "Successful restore removes the consumed trash entry")

    try await fixture.storage.seedDirectory("/storage/emulated/0/Transient")
    try await fixture.storage.seedFile("/storage/emulated/0/Transient/lost-parent.txt", data: Data("payload".utf8))
    let missingParentEntry = try await fixture.service.moveToTrash(at: "/storage/emulated/0/Transient/lost-parent.txt")
    let missingParentEntryPath = try missingParentEntry.entryPath
    try await fixture.storage.deletePermanent("/storage/emulated/0/Transient")
    try await expectThrows("Restore fails safely when its original parent directory is missing") {
        try await fixture.service.restore(missingParentEntry)
    }
    try check(try await fixture.storage.exists(missingParentEntryPath + "/payload"),
              "Missing-parent restore keeps the payload in trash")

    try await fixture.storage.seedDirectory("/storage/emulated/0/Purge")
    try await fixture.storage.seedFile("/storage/emulated/0/Purge/unused", data: Data())
    let purgeEntry = try await fixture.service.moveToTrash(at: "/storage/emulated/0/Purge/unused")
    let purgeEntryPath = try purgeEntry.entryPath
    let otherEntryPath = try pictureEntry.entryPath + "/payload"
    try await fixture.service.permanentlyDelete(purgeEntry)
    try check(try await fixture.storage.exists(purgeEntryPath) == false,
              "Permanent deletion removes the selected trash entry")
    try check(try await fixture.storage.exists(otherEntryPath),
              "Permanent deletion leaves other trash entries untouched")

    let forgedEntry = PhoneTrashEntry(
        id: "../outside",
        originalPath: "/storage/emulated/0/Pictures/same.jpg",
        deletedAt: Date(),
        isDirectory: false
    )
    try await expectThrows("Permanent deletion rejects a forged traversal entry") {
        try await fixture.service.permanentlyDelete(forgedEntry)
    }
    try check(try await fixture.storage.exists(otherEntryPath),
              "A forged trash entry cannot delete a neighboring payload")

    let corruptFixture = PhoneTrashFixture()
    let corruptID = UUID().uuidString.lowercased()
    let corruptRoot = corruptFixture.volume + "/.MacDroidTrash/" + corruptID
    try await corruptFixture.storage.seedDirectory(corruptFixture.volume + "/.MacDroidTrash")
    try await corruptFixture.storage.seedDirectory(corruptRoot)
    try await corruptFixture.storage.seedFile(corruptRoot + "/info.json", data: Data("{\"truncated\":".utf8))
    try await corruptFixture.storage.seedFile(corruptRoot + "/payload", data: Data("user data".utf8))
    try await expectThrows("Malformed or truncated metadata is reported as an error") {
        _ = try await corruptFixture.service.entries(volumePath: corruptFixture.volume)
    }
    try check(try await corruptFixture.storage.exists(corruptRoot + "/payload"),
              "Listing malformed metadata never deletes the corresponding user payload")
    try check(try await corruptFixture.storage.exists(corruptRoot + "/info.json"),
              "Malformed metadata is left intact for recovery")

    print("[PhoneTrashTests] All phone trash checks passed.")
}

@main
private struct PhoneTrashTestRunner {
    static func main() async {
        do {
            try await runPhoneTrashTests()
            exit(0)
        } catch {
            fputs("❌ [PhoneTrashTests] \(error)\n", stderr)
            exit(1)
        }
    }
}
