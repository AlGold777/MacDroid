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

private func makeTempDirectory(_ label: String) throws -> URL {
    let url = FileManager.default.temporaryDirectory.appendingPathComponent("\(label)_\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    return url
}

private func addSession(
    to store: ExternalEditStore,
    name: String = "notes.txt",
    remotePath: String = "/documents/notes.txt",
    fingerprint: String = "phone-key-A",
    data: Data = Data("initial".utf8)
) async throws -> ExternalEditSession {
    let (id, url) = try await store.allocate(fileName: name)
    try data.write(to: url)
    return try await store.register(id: id, fileName: name, remotePath: remotePath,
                                    deviceFingerprint: fingerprint)
}

private func runIdentityAndDigestTests() async throws {
    print("\n[ExternalEditTests] identity and SHA256")
    let root = try makeTempDirectory("external_edit_identity")
    defer { try? FileManager.default.removeItem(at: root) }
    let store = ExternalEditStore(root: root)

    let first = try await addSession(to: store)
    let samePathDifferentPhone = try await addSession(to: store, fingerprint: "phone-key-B")
    let samePhoneDifferentPath = try await addSession(to: store, remotePath: "/archive/notes.txt")
    try check(first.id != samePathDifferentPhone.id && first.id != samePhoneDifferentPath.id,
              "each allocated working copy has an independent session")
    let found = try await store.existing(deviceFingerprint: first.deviceFingerprint, remotePath: first.remotePath)
    let otherPhone = try await store.existing(deviceFingerprint: "phone-key-B", remotePath: first.remotePath)
    let otherPath = try await store.existing(deviceFingerprint: first.deviceFingerprint, remotePath: "/archive/notes.txt")
    let absent = try await store.existing(deviceFingerprint: "phone-key-C", remotePath: first.remotePath)
    try check(found?.id == first.id && otherPhone?.id == samePathDifferentPhone.id &&
              otherPath?.id == samePhoneDifferentPath.id && absent == nil,
              "existing lookup isolates by both phone fingerprint and remote path")

    let working = await store.workingURL(first)
    let initial = try await store.currentDigest(first)
    try check(initial == first.originalDigest, "registered working copy starts at its original digest")
    try Data("changed".utf8).write(to: working, options: .atomic)
    let changed = try await store.currentDigest(first)
    try check(changed != initial, "same-size atomic replacement changes the SHA256 digest")
    try Data("initial".utf8).write(to: working, options: .atomic)
    let reverted = try await store.currentDigest(first)
    try check(reverted == initial, "digest returns to its original value when bytes are reverted")

    let empty = try await addSession(to: store, name: "empty.bin", remotePath: "/documents/empty.bin", data: Data())
    try check(empty.originalDigest == "e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855",
              "zero-byte files receive the standard SHA256 digest")
}

private func runSnapshotTests() async throws {
    print("\n[ExternalEditTests] immutable upload snapshots")
    let root = try makeTempDirectory("external_edit_snapshot")
    defer { try? FileManager.default.removeItem(at: root) }
    let store = ExternalEditStore(root: root)
    let session = try await addSession(to: store, name: "report.md", data: Data("snapshot bytes".utf8))
    let snapshot = try await store.snapshot(session.id)
    let snapshotBytes = try Data(contentsOf: snapshot.url)
    try Data("later editor save".utf8).write(to: await store.workingURL(session), options: .atomic)
    try check(try Data(contentsOf: snapshot.url) == snapshotBytes && snapshotBytes == Data("snapshot bytes".utf8),
              "snapshot bytes remain isolated from a later editor write")
    try check(snapshot.digest == (try ExternalEditStore.digest(snapshot.url)),
              "snapshot digest matches the immutable snapshot file")
    try check(snapshot.remotePath.hasPrefix("/documents/report.edited-") && snapshot.remotePath.hasSuffix(".md"),
              "snapshot destination is a sibling with an edited suffix")

    let rootLevel = try await addSession(to: store, name: "file.txt", remotePath: "/file.txt")
    let rootLevelSnapshot = try await store.snapshot(rootLevel.id)
    try check(rootLevelSnapshot.remotePath.hasPrefix("/") && !rootLevelSnapshot.remotePath.hasPrefix("//") &&
              rootLevelSnapshot.remotePath.hasPrefix("/file.edited-") && rootLevelSnapshot.remotePath.hasSuffix(".txt"),
              "root-level snapshot uses one leading slash and remains a sibling")
}

private func runPersistenceTests() async throws {
    print("\n[ExternalEditTests] persisted upload state")
    let root = try makeTempDirectory("external_edit_persistence")
    defer { try? FileManager.default.removeItem(at: root) }
    let firstStore = ExternalEditStore(root: root)
    let session = try await addSession(to: firstStore)
    let snapshot = try await firstStore.snapshot(session.id)
    try await firstStore.beginUpload(session.id, remotePath: snapshot.remotePath)

    let afterPendingRestart = ExternalEditStore(root: root)
    let pending = try await afterPendingRestart.list().first
    try check(pending?.pendingRemotePath == snapshot.remotePath && pending?.lastSavedPath == nil,
              "pending upload is persisted across store restart")

    try await afterPendingRestart.completeUpload(session.id, snapshot: snapshot)
    let afterCompleteRestart = ExternalEditStore(root: root)
    let complete = try await afterCompleteRestart.list().first
    try check(complete?.pendingRemotePath == nil && complete?.lastSavedPath == snapshot.remotePath &&
              complete?.savedDigest == snapshot.digest,
              "completed upload path and digest are persisted across store restart")
}

private func runCorruptRegistryAndRejectionTests() async throws {
    print("\n[ExternalEditTests] corrupt registry and refused inputs")
    let corruptRoot = try makeTempDirectory("external_edit_corrupt")
    defer { try? FileManager.default.removeItem(at: corruptRoot) }
    let registry = corruptRoot.appendingPathComponent("sessions.json")
    let corruptBytes = Data("{broken registry".utf8)
    try corruptBytes.write(to: registry)
    let corruptStore = ExternalEditStore(root: corruptRoot)
    try await expectThrows("corrupt registry is rejected") {
        _ = try await corruptStore.list()
    }
    try check(try Data(contentsOf: registry) == corruptBytes, "corrupt registry bytes are left untouched")

    let root = try makeTempDirectory("external_edit_rejections")
    defer { try? FileManager.default.removeItem(at: root) }
    let store = ExternalEditStore(root: root)
    for name in ["", ".", "..", "../escape.txt", "nested/file.txt", "bad\0name"] {
        try await expectThrows("invalid filename \(String(reflecting: name)) is rejected") {
            _ = try await store.allocate(fileName: name)
        }
    }

    let (missingID, _) = try await store.allocate(fileName: "missing.txt")
    try await expectThrows("register refuses a missing working file") {
        _ = try await store.register(id: missingID, fileName: "missing.txt", remotePath: "/documents/missing.txt",
                                     deviceFingerprint: "phone-key-A")
    }

    let (linkID, linkURL) = try await store.allocate(fileName: "linked.txt")
    let target = root.appendingPathComponent("outside-target.txt")
    try Data("target".utf8).write(to: target)
    try FileManager.default.createSymbolicLink(at: linkURL, withDestinationURL: target)
    try await expectThrows("register refuses a symbolic-link working file") {
        _ = try await store.register(id: linkID, fileName: "linked.txt", remotePath: "/documents/linked.txt",
                                     deviceFingerprint: "phone-key-A")
    }
    try check(try Data(contentsOf: target) == Data("target".utf8), "symbolic-link target bytes remain intact")
}

private func runLongUnicodeNameTest() throws {
    print("\n[ExternalEditTests] generated copy names")
    let token = "01234567-89ab-cdef-0123-456789abcdef"
    let longName = String(repeating: "🙂", count: 100) + "." + String(repeating: "x", count: 40)
    let generated = ExternalEditStore.copyName(longName, token: token)
    let base = (generated as NSString).deletingPathExtension
    try check(generated.utf8.count <= 220 && base.utf8.count <= 160,
              "long Unicode filename is truncated on UTF-8 boundaries")
    try check(generated.contains(".edited-\(token)") && !generated.hasSuffix("." + String(repeating: "x", count: 40)),
              "overlong extension is omitted while preserving the edited token")
}

@main
private struct ExternalEditTests {
    static func main() async {
        do {
            try await runIdentityAndDigestTests()
            try await runSnapshotTests()
            try await runPersistenceTests()
            try await runCorruptRegistryAndRejectionTests()
            try runLongUnicodeNameTest()
            print("\nExternalEditTests passed")
        } catch {
            fputs("\nExternalEditTests failed: \(error)\n", stderr)
            exit(1)
        }
    }
}
