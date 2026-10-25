import Foundation
import CryptoKit
import MacHostCore

private struct TestFailure: Error, CustomStringConvertible {
    let description: String
}

private final class Flag: @unchecked Sendable {
    private let lock = NSLock()
    private var value = false
    func set() { lock.lock(); value = true; lock.unlock() }
    func check() throws {
        lock.lock(); defer { lock.unlock() }
        if value { throw NSError(domain: "session", code: 1) }
    }
    func isSet() -> Bool { lock.lock(); defer { lock.unlock() }; return value }
}

private func check(_ condition: Bool, _ message: String) throws {
    guard condition else { throw TestFailure(description: message) }
    print("  ✓ \(message)")
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

private func item(_ path: String, source: FileSource, size: UInt64 = 4,
                  directory: Bool = false, symlink: Bool = false, mtime: Double = 10) -> FileItem {
    FileItem(id: path, name: URL(fileURLWithPath: path).lastPathComponent, path: path,
             size: size, mtime: mtime, isDirectory: directory, source: source, isSymbolicLink: symlink)
}

private let trashID = "00000000-0000-4000-8000-000000000001"

private actor Fixture {
    var bytes: [String: Data]
    var kinds: [String: (directory: Bool, symlink: Bool)] = [:]
    var digestCounts: [String: Int] = [:]
    var moveCount = 0
    var failRestore = false

    init(_ bytes: [String: Data]) { self.bytes = bytes }
    func set(_ path: String, _ data: Data) { bytes[path] = data }
    func setKind(_ path: String, directory: Bool, symlink: Bool) { kinds[path] = (directory, symlink) }
    func failRestoreNow() { failRestore = true }
    func digest(_ file: FileItem) throws -> String {
        digestCounts[file.path, default: 0] += 1
        guard let data = bytes[file.path] else { throw NSError(domain: "fixture", code: 1) }
        return CryptoKit.SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }
    func metadata(_ path: String, source: FileSource) throws -> FileItem {
        guard let data = bytes[path] else { throw NSError(domain: "fixture", code: 2) }
        let kind = kinds[path] ?? (false, false)
        return item(path, source: source, size: UInt64(data.count), directory: kind.directory, symlink: kind.symlink)
    }
    func count(_ path: String) -> Int { digestCounts[path, default: 0] }
    func contains(_ path: String) -> Bool { bytes[path] != nil }
    func move(_ phone: FileItem, beforeMove: @escaping CopyDoneService.BeforeMove) async throws -> PhoneTrashEntry {
        try await beforeMove()
        moveCount += 1
        let path = "/storage/emulated/0/.MacDroidTrash/\(trashID)/payload"
        if let data = bytes.removeValue(forKey: phone.path) { bytes[path] = data }
        return PhoneTrashEntry(id: trashID, originalPath: phone.path, deletedAt: Date(), isDirectory: false)
    }
    func restore(_ entry: PhoneTrashEntry) throws {
        if failRestore { throw NSError(domain: "fixture", code: 3) }
        let path = try entry.entryPath + "/payload"
        if let data = bytes.removeValue(forKey: path) { bytes[entry.originalPath] = data }
    }
    func moves() -> Int { moveCount }
}

private func service(_ fixture: Fixture, validate: @escaping CopyDoneService.Validate = {}) -> CopyDoneService {
    CopyDoneService(metadata: { path, source in try await fixture.metadata(path, source: source) },
                    contentDigest: { try await fixture.digest($0) }, validateSession: validate)
}

private func run() async throws {
    print("\n[CopyDoneTests] Fresh verification and scope")
    let phone = "/storage/emulated/0/DCIM/a.bin"
    let data = Data("same".utf8)
    let mac1 = "/Users/test/Imports/a.bin"
    let mac2 = "/Users/test/Imports/second/a.bin"
    let fixture = Fixture([phone: data, mac1: data, mac2: data,
                           "/Users/test/Imports/wrong.bin": Data("xxxx".utf8)])
    let svc = service(fixture)
    let scan = try await svc.findCopies(
        locations: [CopyDoneLocation(phonePath: "/sdcard/DCIM/a.bin", macPath: mac1),
                    CopyDoneLocation(phonePath: phone, macPath: mac1),
                    CopyDoneLocation(phonePath: phone, macPath: mac2),
                    CopyDoneLocation(phonePath: phone, macPath: "/Users/test/Imports/wrong.bin"),
                    CopyDoneLocation(phonePath: "/storage/emulated/0/DCIM2/a.bin", macPath: mac1)],
        scopes: [CopyDoneScope(path: "/storage/emulated/0/DCIM", isDirectory: true)])
    try check(scan.entries.count == 1 && scan.entries[0].macCopies.count == 2,
              "Fresh content digest confirms all matching copies and excludes same-size different bytes")
    try check(scan.candidateCount == 1, "Directory scope respects path boundaries and canonical phone aliases")
    try check(await fixture.count(phone) == 1, "A phone file is hashed once despite multiple Mac locations")

    let removedMac = Fixture([phone: data])
    let missing = try await service(removedMac).findCopies(
        locations: [CopyDoneLocation(phonePath: phone, macPath: mac1)],
        scopes: [CopyDoneScope(path: phone, isDirectory: false)])
    try check(missing.entries.isEmpty, "A missing Mac copy is not offered")
    try check(await removedMac.count(phone) == 0,
              "The full phone file is not hashed when no readable Mac candidate exists")

    let changed = Fixture([phone: data, mac1: Data("diff".utf8)])
    let changedScan = try await service(changed).findCopies(
        locations: [CopyDoneLocation(phonePath: phone, macPath: mac1)],
        scopes: [CopyDoneScope(path: phone, isDirectory: false)])
    try check(changedScan.entries.isEmpty, "A changed Mac copy is not offered")

    for (directory, symlink, label) in [(true, false, "Directories"), (false, true, "Symlinks")] {
        let invalidFixture = Fixture([phone: data, mac1: data])
        await invalidFixture.setKind(phone, directory: directory, symlink: symlink)
        let invalid = try await service(invalidFixture).findCopies(
            locations: [CopyDoneLocation(phonePath: phone, macPath: mac1)],
            scopes: [CopyDoneScope(path: phone, isDirectory: false)])
        try check(invalid.entries.isEmpty, "\(label) are rejected by content metadata validation")
    }

    try check(CopyDoneScope(path: "/x/folder", isDirectory: true).contains("/x/folder/a") &&
              !CopyDoneScope(path: "/x/folder", isDirectory: true).contains("/x/folder-old/a"),
              "Directory scopes include descendants but not similarly prefixed siblings")
    try check(CopyDoneService.phonePath("/mnt/sdcard/a") == "/storage/emulated/0/a" &&
              CopyDoneService.phonePath("/storage/self/primary/a") == "/storage/emulated/0/a",
              "Supported phone storage aliases normalize to one canonical path")

    let localRoot = FileManager.default.temporaryDirectory.appendingPathComponent("copy_done_local_\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: localRoot, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: localRoot) }
    let ordinary = localRoot.appendingPathComponent("ordinary.bin")
    let folder = localRoot.appendingPathComponent("folder", isDirectory: true)
    let trash = localRoot.appendingPathComponent(PhoneTrashService.directoryName, isDirectory: true)
    try Data("same".utf8).write(to: ordinary)
    try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: false)
    try FileManager.default.createDirectory(at: trash, withIntermediateDirectories: false)
    let trashed = trash.appendingPathComponent("payload")
    try Data("same".utf8).write(to: trashed)
    let link = localRoot.appendingPathComponent("link.bin")
    try FileManager.default.createSymbolicLink(at: link, withDestinationURL: ordinary)
    try check(try CopyDoneService.localMetadata(ordinary.path).size == 4,
              "Real local metadata accepts a regular file")
    for path in [folder.path, link.path, trashed.path] {
        try await expectThrows("Local directories, symlinks, and trash payloads are rejected") {
            _ = try CopyDoneService.localMetadata(path)
        }
    }

    print("\n[CopyDoneTests] Safe move, races, cancellation, and partial results")
    let validFixture = Fixture([phone: data, mac1: data])
    let validService = service(validFixture)
    let validScan = try await validService.findCopies(locations: [CopyDoneLocation(phonePath: phone, macPath: mac1)],
                                                      scopes: [CopyDoneScope(path: phone, isDirectory: false)])
    let entry = validScan.entries[0]
    let changedPhone = Fixture([phone: data, mac1: data])
    let changedPhoneSvc = service(changedPhone)
    let oldScan = try await changedPhoneSvc.findCopies(locations: [CopyDoneLocation(phonePath: phone, macPath: mac1)],
                                                       scopes: [CopyDoneScope(path: phone, isDirectory: false)])
    await changedPhone.set(phone, Data("edit".utf8))
    let renameFlag = Flag()
    try await expectThrows("Changed phone content aborts before rename") {
        _ = try await changedPhoneSvc.moveSelected(entries: oldScan.entries, selectedIDs: [oldScan.entries[0].id],
            moveToTrash: { _, before in try await before(); renameFlag.set(); throw NSError(domain: "test", code: 1) },
            restore: { _ in })
    }
    try check(!renameFlag.isSet(), "Before-move validation runs before any rename")

    let changedMacFixture = Fixture([phone: data, mac1: data])
    let changedMacSvc = service(changedMacFixture)
    let changedMacScan = try await changedMacSvc.findCopies(locations: [CopyDoneLocation(phonePath: phone, macPath: mac1)],
                                                            scopes: [CopyDoneScope(path: phone, isDirectory: false)])
    await changedMacFixture.set(mac1, Data("edit".utf8))
    try await expectThrows("Changed Mac copy aborts before rename") {
        _ = try await changedMacSvc.moveSelected(entries: changedMacScan.entries, selectedIDs: [changedMacScan.entries[0].id],
            moveToTrash: { _, before in try await before(); throw NSError(domain: "test", code: 1) }, restore: { _ in })
    }

    // Model a payload race after rename; service must restore and report no completion.
    let raceFixture = Fixture([phone: data, mac1: data])
    let raceService = service(raceFixture)
    let raceScan = try await raceService.findCopies(locations: [CopyDoneLocation(phonePath: phone, macPath: mac1)],
                                                    scopes: [CopyDoneScope(path: phone, isDirectory: false)])
    try await expectThrows("Changed post-rename payload is rolled back") {
        _ = try await raceService.moveSelected(entries: raceScan.entries, selectedIDs: [raceScan.entries[0].id],
            moveToTrash: { file, before in
                try await before()
                let trash = PhoneTrashEntry(id: trashID, originalPath: file.path, deletedAt: Date(), isDirectory: false)
                await raceFixture.set(try trash.entryPath + "/payload", Data("edit".utf8))
                return trash
            }, restore: { try await raceFixture.restore($0) })
    }
    try check(await raceFixture.contains(phone),
              "Successful rollback restores the original phone path")

    let failedRestoreFixture = Fixture([phone: data, mac1: data])
    let failedRestoreSvc = service(failedRestoreFixture)
    let failedRestoreScan = try await failedRestoreSvc.findCopies(locations: [CopyDoneLocation(phonePath: phone, macPath: mac1)],
                                                                  scopes: [CopyDoneScope(path: phone, isDirectory: false)])
    await failedRestoreFixture.failRestoreNow()
    try await expectThrows("Rollback failure is reported without claiming completion") {
        _ = try await failedRestoreSvc.moveSelected(entries: failedRestoreScan.entries,
            selectedIDs: [failedRestoreScan.entries[0].id],
            moveToTrash: { file, before in
                try await before()
                return PhoneTrashEntry(id: trashID, originalPath: file.path, deletedAt: Date(), isDirectory: false)
            }, restore: { try await failedRestoreFixture.restore($0) })
    }

    let sessionFlag = Flag()
    let sessionFixture = Fixture([phone: data, mac1: data])
    let sessionSvc = service(sessionFixture, validate: { try sessionFlag.check() })
    let sessionScan = try await sessionSvc.findCopies(locations: [CopyDoneLocation(phonePath: phone, macPath: mac1)],
                                                      scopes: [CopyDoneScope(path: phone, isDirectory: false)])
    try await expectThrows("A session change after rename blocks unsafe follow-up") {
        _ = try await sessionSvc.moveSelected(entries: sessionScan.entries, selectedIDs: [sessionScan.entries[0].id],
            moveToTrash: { file, before in
                try await before()
                sessionFlag.set()
                return PhoneTrashEntry(id: trashID, originalPath: file.path, deletedAt: Date(), isDirectory: false)
            }, restore: { _ in })
    }

    let phone2 = "/storage/emulated/0/DCIM/b.bin"
    let macB = "/Users/test/Imports/b.bin"
    let partialFixture = Fixture([phone: data, mac1: data, phone2: data, macB: data])
    let partialSvc = service(partialFixture)
    let partialScan = try await partialSvc.findCopies(
        locations: [CopyDoneLocation(phonePath: phone, macPath: mac1), CopyDoneLocation(phonePath: phone2, macPath: macB)],
        scopes: [CopyDoneScope(path: "/storage/emulated/0/DCIM", isDirectory: true)])
    do {
        _ = try await partialSvc.moveSelected(entries: partialScan.entries,
            selectedIDs: Set(partialScan.entries.map(\.id)),
            moveToTrash: { file, before in
                if file.path == phone2 { throw NSError(domain: "injected", code: 7) }
                return try await partialFixture.move(file, beforeMove: before)
            }, restore: { try await partialFixture.restore($0) })
        throw TestFailure(description: "Expected second-item move to fail")
    } catch let error as CopyDoneCleanupError {
        let originalStillExists = await partialFixture.contains(phone)
        try check(error.completedIDs.count == 1 && !originalStillExists,
                  "Partial failure reports one completed item and preserves its completed move")
        try check(await partialFixture.contains(phone2), "An item after the failure remains at its source path")
    }

    let cancelled = Fixture([phone: data, mac1: data])
    let cancelSvc = service(cancelled)
    let cancelScan = try await cancelSvc.findCopies(locations: [CopyDoneLocation(phonePath: phone, macPath: mac1)],
                                                    scopes: [CopyDoneScope(path: phone, isDirectory: false)])
    try await expectThrows("Cancelled cleanup does not rename") {
        let task = Task { try await cancelSvc.moveSelected(entries: cancelScan.entries, selectedIDs: [cancelScan.entries[0].id],
            moveToTrash: { _, before in try await before(); return PhoneTrashEntry(id: trashID, originalPath: phone, deletedAt: Date(), isDirectory: false) },
            restore: { _ in }) }
        task.cancel()
        _ = try await task.value
    }
    try check(await cancelled.moves() == 0, "Cancellation before the operation leaves the phone file untouched")

    // Journal history is only a scoped candidate source: state and device/session constrain discovery.
    print("\n[CopyDoneTests] Transfer journal candidate filtering")
    let db = FileManager.default.temporaryDirectory.appendingPathComponent("copy_done_\(UUID().uuidString).sqlite")
    defer { try? FileManager.default.removeItem(at: db) }
    let journal = try TransferJournal(databaseURL: db)
    func register(_ id: String, session: String, direction: String, state: String, src: String) throws {
        try journal.registerTransfer(transferId: id, sessionIdentity: session, direction: direction,
            sourcePath: src, sourceSize: 4, sourceMtime: 1, sourceHash: "stale", targetFinalPath: "/Mac/\(id)",
            targetTempPath: "/Mac/\(id).part", expectedSize: 4, state: state)
    }
    try register("a", session: "device-1:host-a", direction: "download", state: "completed", src: phone)
    try register("b", session: "device-1:host-b", direction: "download", state: "completed", src: phone)
    try register("c", session: "device-2:host-a", direction: "download", state: "completed", src: phone)
    try register("d", session: "device-1:host-a", direction: "upload", state: "completed", src: phone)
    try register("e", session: "device-1:host-a", direction: "download", state: "running", src: phone)
    let candidates = journal.copyDoneLocations(deviceID: "device-1", sessionIdentity: "device-1:host-z")
    try check(candidates.count == 2 && candidates.allSatisfy { $0.macPath == "/Mac/a" || $0.macPath == "/Mac/b" },
              "Only completed downloads for the matching device or exact session are candidate locations")
    try check(entry.id == CopyDoneService.phonePath(phone), "Entry identity uses canonical phone path")
}

@main private struct CopyDoneTestRunner {
    static func main() async {
        do { try await run(); print("\n[CopyDoneTests] All checks passed.") }
        catch { fputs("❌ [CopyDoneTests] \(error)\n", stderr); exit(1) }
    }
}
