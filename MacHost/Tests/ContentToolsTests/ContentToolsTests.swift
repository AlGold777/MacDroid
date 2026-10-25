import Foundation
import MacHostCore

private struct TestFailure: Error, CustomStringConvertible {
    let description: String
}

private struct ListingFailure: Error, Equatable {}
private struct DigestFailure: Error, Equatable {}

private struct ZIPFixtureEntry {
    let path: String
    let data: Data
    var directory = false
    var symlink = false
    var encrypted = false
    var declaredSize: UInt32?
    var corruptCRC = false
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

private func item(
    _ name: String,
    _ path: String,
    directory: Bool = false,
    size: UInt64 = 0,
    mtime: Double = 100,
    source: FileSource = .localMac
) -> FileItem {
    FileItem(id: path, name: name, path: path, size: size, mtime: mtime,
             isDirectory: directory, source: source)
}

private actor TestTree {
    private let listings: [String: [FileItem]]
    private let digests: [String: String]
    private var digestCalls: [String] = []

    init(listings: [String: [FileItem]] = [:], digests: [String: String] = [:]) {
        self.listings = listings
        self.digests = digests
    }

    func list(_ directory: FileItem) throws -> [FileItem] {
        guard let children = listings[directory.path] else { throw ListingFailure() }
        return children
    }

    func digest(_ file: FileItem) throws -> String {
        digestCalls.append(file.path)
        guard let digest = digests[file.path] else { throw DigestFailure() }
        return digest
    }

    func digestCallPaths() -> [String] { digestCalls }
}

private final class LockedProgress: @unchecked Sendable {
    private let lock = NSLock()
    private var values: [Int] = []

    func append(_ value: Int) {
        lock.lock()
        values.append(value)
        lock.unlock()
    }

    func snapshot() -> [Int] {
        lock.lock()
        defer { lock.unlock() }
        return values
    }
}

private final class LockedPaths: @unchecked Sendable {
    private let lock = NSLock()
    private var values: [String] = []

    func append(_ value: String) {
        lock.lock()
        values.append(value)
        lock.unlock()
    }

    func snapshot() -> [String] {
        lock.lock()
        defer { lock.unlock() }
        return values
    }
}

private func localItem(at url: URL) throws -> FileItem {
    let values = try url.resourceValues(forKeys: [.fileSizeKey, .contentModificationDateKey])
    guard let size = values.fileSize, let mtime = values.contentModificationDate else {
        throw TestFailure(description: "Could not read test file metadata at \(url.path)")
    }
    return item(url.lastPathComponent, url.path, size: UInt64(size),
                mtime: mtime.timeIntervalSince1970)
}

private func makeTempDirectory(_ label: String) throws -> URL {
    let url = FileManager.default.temporaryDirectory.appendingPathComponent("\(label)_\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    return url
}

private func appendLE<T: FixedWidthInteger>(_ value: T, to data: inout Data) {
    var littleEndian = value.littleEndian
    withUnsafeBytes(of: &littleEndian) { data.append(contentsOf: $0) }
}

private func crc32(_ data: Data) -> UInt32 {
    var crc: UInt32 = 0xffff_ffff
    for byte in data {
        crc ^= UInt32(byte)
        for _ in 0..<8 {
            crc = (crc & 1) == 1 ? (crc >> 1) ^ 0xedb8_8320 : crc >> 1
        }
    }
    return ~crc
}

private func writeZIP(_ entries: [ZIPFixtureEntry], to url: URL, corruptPayloadAt indexToCorrupt: Int? = nil) throws {
    struct CentralRecord {
        let entry: ZIPFixtureEntry
        let name: Data
        let crc: UInt32
        let size: UInt32
        let localOffset: UInt32
    }

    var archive = Data()
    var records: [CentralRecord] = []
    var corruptOffset: Int?
    for (index, entry) in entries.enumerated() {
        let name = Data(entry.path.utf8)
        let offset = UInt32(archive.count)
        let plainCRC = crc32(entry.data)
        let crc = entry.corruptCRC ? plainCRC ^ 1 : plainCRC
        let size = entry.declaredSize ?? UInt32(entry.data.count)
        let flags: UInt16 = (entry.encrypted ? 1 : 0) | 0x0800 // UTF-8 names
        appendLE(UInt32(0x04034b50), to: &archive) // local file header
        appendLE(UInt16(20), to: &archive)
        appendLE(flags, to: &archive)
        appendLE(UInt16(0), to: &archive) // stored
        appendLE(UInt16(0), to: &archive)
        appendLE(UInt16(0), to: &archive)
        appendLE(crc, to: &archive)
        appendLE(size, to: &archive)
        appendLE(size, to: &archive)
        appendLE(UInt16(name.count), to: &archive)
        appendLE(UInt16(0), to: &archive)
        archive.append(name)
        if index == indexToCorrupt { corruptOffset = archive.count }
        archive.append(entry.data)
        records.append(CentralRecord(entry: entry, name: name, crc: crc, size: size, localOffset: offset))
    }

    let centralOffset = UInt32(archive.count)
    for record in records {
        appendLE(UInt32(0x02014b50), to: &archive) // central directory file header
        appendLE(UInt16(0x0314), to: &archive) // Unix, version 2.0
        appendLE(UInt16(20), to: &archive)
        appendLE((record.entry.encrypted ? UInt16(1) : UInt16(0)) | 0x0800, to: &archive)
        appendLE(UInt16(0), to: &archive) // stored
        appendLE(UInt16(0), to: &archive)
        appendLE(UInt16(0), to: &archive)
        appendLE(record.crc, to: &archive)
        appendLE(record.size, to: &archive)
        appendLE(record.size, to: &archive)
        appendLE(UInt16(record.name.count), to: &archive)
        appendLE(UInt16(0), to: &archive) // extra
        appendLE(UInt16(0), to: &archive) // comment
        appendLE(UInt16(0), to: &archive) // disk
        appendLE(UInt16(0), to: &archive) // internal attrs
        let mode: UInt32 = record.entry.directory ? 0o040755 : (record.entry.symlink ? 0o120777 : 0o100644)
        appendLE(mode << 16, to: &archive)
        appendLE(record.localOffset, to: &archive)
        archive.append(record.name)
    }
    let centralSize = UInt32(archive.count) - centralOffset
    appendLE(UInt32(0x06054b50), to: &archive) // end of central directory
    appendLE(UInt16(0), to: &archive)
    appendLE(UInt16(0), to: &archive)
    appendLE(UInt16(records.count), to: &archive)
    appendLE(UInt16(records.count), to: &archive)
    appendLE(centralSize, to: &archive)
    appendLE(centralOffset, to: &archive)
    appendLE(UInt16(0), to: &archive)
    if let corruptOffset, corruptOffset < archive.count { archive[corruptOffset] ^= 0xff }
    try archive.write(to: url, options: .atomic)
}

private func runContentDigestTests() async throws {
    print("\n[ContentToolsTests] FileContentService")
    let root = try makeTempDirectory("content_digest")
    defer { try? FileManager.default.removeItem(at: root) }
    let fileURL = root.appendingPathComponent("exact.txt")
    try Data("abc".utf8).write(to: fileURL)
    let service = FileContentService(transport: TransportMultiplexer())
    let digest = try await service.digest(localItem(at: fileURL))
    try check(digest == "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad",
              "Local file digest is the exact SHA-256 of its bytes")

    let directory = item("directory", root.path, directory: true)
    try await expectThrows("Directories cannot be hashed as file contents") {
        _ = try await service.digest(directory)
    }

    let missing = item("missing", root.appendingPathComponent("missing.bin").path)
    try await expectThrows("Local content read errors propagate") {
        _ = try await service.digest(missing)
    }
}

private func runExactComparatorTests() async throws {
    print("\n[ContentToolsTests] Exact DirectoryComparator")
    let comparator = DirectoryComparator()

    let leftBytes = item("same.bin", "/left/same.bin", size: 4, mtime: 100)
    let rightBytes = item("same.bin", "/right/same.bin", size: 4, mtime: 100)
    let sameMetadataDifferentBytes = try await comparator.compare(
        left: [leftBytes], right: [rightBytes], listDirectory: { _ in [] },
        contentDigest: { $0.path == leftBytes.path ? "aaaa" : "bbbb" }
    )
    try check(sameMetadataDifferentBytes.different == ["same.bin"] && sameMetadataDifferentBytes.identical.isEmpty,
              "Same-size files with matching metadata but different digests are different")

    let leftMtime = item("mtime.bin", "/left/mtime.bin", size: 3, mtime: 100)
    let rightMtime = item("mtime.bin", "/right/mtime.bin", size: 3, mtime: 900)
    let sameBytesDifferentMtime = try await comparator.compare(
        left: [leftMtime], right: [rightMtime], listDirectory: { _ in [] },
        contentDigest: { _ in "same-content" }
    )
    try check(sameBytesDifferentMtime.identical == ["mtime.bin"] && sameBytesDifferentMtime.different.isEmpty,
              "Different modification times do not prevent identical byte content")

    let sizeLeft = item("large.bin", "/left/large.bin", size: 4)
    let sizeRight = item("large.bin", "/right/large.bin", size: 5)
    let sizeCounter = TestTree()
    let sizeMismatch = try await comparator.compare(
        left: [sizeLeft], right: [sizeRight], listDirectory: { _ in [] },
        contentDigest: { file in try await sizeCounter.digest(file) }
    )
    let sizeDigestPaths = await sizeCounter.digestCallPaths()
    try check(sizeMismatch.different == ["large.bin"] && sizeDigestPaths.isEmpty,
              "Different-size files are classified without hashing")

    let leftRoot = item("tree", "/left/tree", directory: true)
    let rightRoot = item("tree", "/right/tree", directory: true)
    let leftDeep = item("deep", "/left/tree/nested/deep", directory: true)
    let rightDeep = item("deep", "/right/tree/nested/deep", directory: true)
    let leftNested = item("nested", "/left/tree/nested", directory: true)
    let rightNested = item("nested", "/right/tree/nested", directory: true)
    let leftLeaf = item("leaf.bin", "/left/tree/nested/deep/leaf.bin", size: 3, mtime: 100)
    let rightLeaf = item("leaf.bin", "/right/tree/nested/deep/leaf.bin", size: 3, mtime: 500)
    let tree = TestTree(
        listings: [
            leftRoot.path: [leftNested], rightRoot.path: [rightNested],
            leftNested.path: [leftDeep], rightNested.path: [rightDeep],
            leftDeep.path: [leftLeaf], rightDeep.path: [rightLeaf]
        ],
        digests: [leftLeaf.path: "leaf-digest", rightLeaf.path: "leaf-digest"]
    )
    let nestedEqual = try await comparator.compare(
        left: [leftRoot], right: [rightRoot],
        listDirectory: { try await tree.list($0) },
        contentDigest: { try await tree.digest($0) }
    )
    try check(nestedEqual.identical == ["tree"],
              "Nested files with equal bytes compare identical despite different modification times")

    do {
        _ = try await comparator.compare(
            left: [leftRoot], right: [rightRoot],
            listDirectory: { directory in
                let childPath = directory.path + "/next"
                return [item("next", childPath, directory: true, source: directory.source)]
            },
            contentDigest: { _ in "unused" }
        )
        throw TestFailure(description: "Expected recursive comparison depth limit")
    } catch let error as TestFailure {
        throw error
    } catch {
        try check(error.localizedDescription.contains("глубина"),
                  "Recursive directory comparison rejects depth greater than 256")
    }

    try await expectThrows("Digest failures abort exact comparison") {
        _ = try await comparator.compare(
            left: [leftBytes], right: [rightBytes], listDirectory: { _ in [] },
            contentDigest: { _ in throw DigestFailure() }
        )
    }
}

private func runDuplicateFinderTests() async throws {
    print("\n[ContentToolsTests] DuplicateFinder")
    let root = item("root", "/scan", directory: true)
    let nested = item("nested", "/scan/nested", directory: true)
    let hidden = item(".hidden", "/scan/.hidden", size: 4)
    let copy = item("copy.bin", "/scan/nested/copy.bin", size: 4)
    let distinctSize = item("other.bin", "/scan/other.bin", size: 9)
    let trash = item(".MacDroidTrash", "/scan/.MacDroidTrash", directory: true)
    let trashedCopy = item("payload", "/scan/.MacDroidTrash/entry/payload", size: 4)
    let outsideCopy = item("outside.bin", "/elsewhere/outside.bin", size: 4)
    let tree = TestTree(
        listings: [root.path: [hidden, nested, distinctSize, trash],
                   nested.path: [copy], trash.path: [trashedCopy]],
        digests: [hidden.path: "aabb", copy.path: "aabb", outsideCopy.path: "aabb"]
    )
    let progress = LockedProgress()
    let finder = DuplicateFinder(
        listDirectory: { try await tree.list($0) },
        contentDigest: { try await tree.digest($0) },
        progress: { progress.append($0) }
    )
    let groups = try await finder.findDuplicates(roots: [root, nested, outsideCopy])
    try check(groups.count == 1 && groups[0].digest == "aabb" && groups[0].size == 4,
              "Exact duplicate content forms one size-and-digest group")
    try check(groups[0].items.map(\.path).sorted() == [hidden.path, copy.path, outsideCopy.path].sorted(),
              "Hidden files are included while trash payloads are excluded")
    let digestPaths = await tree.digestCallPaths()
    try check(digestPaths.count == 3 && !digestPaths.contains(distinctSize.path)
              && !digestPaths.contains(trashedCopy.path),
              "Different-size singleton and trash payloads are not hashed")
    try check(progress.snapshot().last == 4,
              "Progress advances once per unique file path across overlapping roots")

    let readFailureFinder = DuplicateFinder(
        listDirectory: { _ in throw ListingFailure() },
        contentDigest: { _ in "unused" }
    )
    try await expectThrows("Directory listing errors abort duplicate search") {
        _ = try await readFailureFinder.findDuplicates(roots: [root])
    }

    let digestFailureFinder = DuplicateFinder(
        listDirectory: { _ in [] },
        contentDigest: { _ in throw DigestFailure() }
    )
    try await expectThrows("Digest errors abort duplicate search") {
        _ = try await digestFailureFinder.findDuplicates(roots: [hidden, copy])
    }

    let cycleRoot = item("cycle", "/cycle", directory: true)
    let cycleFinder = DuplicateFinder(
        listDirectory: { _ in [cycleRoot] },
        contentDigest: { _ in "unused" }
    )
    try await expectThrows("Local directory cycles are rejected") {
        _ = try await cycleFinder.findDuplicates(roots: [cycleRoot])
    }

    let deepFinder = DuplicateFinder(
        listDirectory: { directory in
            [item("next", directory.path + "/next", directory: true, source: directory.source)]
        },
        contentDigest: { _ in "unused" }
    )
    do {
        _ = try await deepFinder.findDuplicates(roots: [root])
        throw TestFailure(description: "Expected duplicate search depth limit")
    } catch let error as TestFailure {
        throw error
    } catch {
        try check(error.localizedDescription.contains("256"),
                  "Duplicate search rejects directory depth greater than 256")
    }

    let phoneRoot = item("phone", "/storage/emulated/0/DCIM", directory: true, source: .remotePhone)
    let phoneOne = item("phone-one.bin", "/storage/emulated/0/DCIM/one.bin", size: 7, source: .remotePhone)
    let phoneTwo = item("phone-two.bin", "/storage/emulated/0/DCIM/two.bin", size: 7, source: .remotePhone)
    let remoteTree = TestTree(listings: [phoneRoot.path: [phoneOne, phoneTwo]],
                              digests: [phoneOne.path: "remote-identical", phoneTwo.path: "remote-identical"])
    let remoteFinder = DuplicateFinder(
        listDirectory: { try await remoteTree.list($0) },
        contentDigest: { try await remoteTree.digest($0) }
    )
    let remoteGroups = try await remoteFinder.findDuplicates(roots: [phoneRoot])
    try check(remoteGroups.count == 1 && Set(remoteGroups[0].items.map(\.source)) == [.remotePhone],
              "Duplicate search works with injected remote listings and digests without a connected phone")

    let cancellationFinder = DuplicateFinder(
        listDirectory: { _ in
            withUnsafeCurrentTask { $0?.cancel() }
            return []
        },
        contentDigest: { _ in "unused" }
    )
    let cancelledTask = Task { try await cancellationFinder.findDuplicates(roots: [root]) }
    do {
        _ = try await cancelledTask.value
        throw TestFailure(description: "Expected cancellation during duplicate traversal")
    } catch is CancellationError {
        try check(true, "Duplicate search responds to task cancellation")
    }
}

private func runDuplicateCleanupTests() async throws {
    print("\n[ContentToolsTests] DuplicateCleanupService safety")
    let first = item("first.bin", "/duplicates/first.bin", size: 4)
    let second = item("second.bin", "/duplicates/second.bin", size: 4)
    let third = item("third.bin", "/duplicates/third.bin", size: 4)
    let group = DuplicateGroup(digest: "trusted-digest", size: 4, items: [first, second, third])
    let allSelectedCalls = LockedPaths()
    let allSelectedService = DuplicateCleanupService(
        contentDigest: { _ in "trusted-digest" },
        moveToTrash: { allSelectedCalls.append($0.path) }
    )
    try await expectThrows("Cleanup refuses to remove every copy in a duplicate group") {
        try await allSelectedService.removeSelected(
            groups: [group],
            selectedIDs: Set(group.items.map(DuplicateCleanupService.itemID))
        )
    }
    try check(allSelectedCalls.snapshot().isEmpty,
              "All-copies-selected rejection does not move anything to trash")

    let changedCalls = LockedPaths()
    let changedService = DuplicateCleanupService(
        contentDigest: { item in item.path == second.path ? "changed-content" : "trusted-digest" },
        moveToTrash: { changedCalls.append($0.path) }
    )
    try await expectThrows("Cleanup rejects selected content that changed after duplicate search") {
        try await changedService.removeSelected(
            groups: [group], selectedIDs: [DuplicateCleanupService.itemID(second)]
        )
    }
    try check(changedCalls.snapshot().isEmpty,
              "Changed selected content is rejected before any trash operation")

    let keeperChangedCalls = LockedPaths()
    let keeperChangedService = DuplicateCleanupService(
        contentDigest: { item in item.path == first.path ? "changed-content" : "trusted-digest" },
        moveToTrash: { keeperChangedCalls.append($0.path) }
    )
    try await expectThrows("Cleanup rejects a keeper that changed after duplicate search") {
        try await keeperChangedService.removeSelected(
            groups: [group], selectedIDs: [DuplicateCleanupService.itemID(second)]
        )
    }
    try check(keeperChangedCalls.snapshot().isEmpty,
              "Changed keeper is rejected before any trash operation")

    let partialCalls = LockedPaths()
    let partialService = DuplicateCleanupService(
        contentDigest: { _ in "trusted-digest" },
        moveToTrash: { partialCalls.append($0.path) }
    )
    try await partialService.removeSelected(
        groups: [group],
        selectedIDs: [DuplicateCleanupService.itemID(second), DuplicateCleanupService.itemID(third)]
    )
    try check(Set(partialCalls.snapshot()) == Set([second.path, third.path]),
              "Valid partial selection moves only the selected copies to trash")

    let unknownCalls = LockedPaths()
    let unknownService = DuplicateCleanupService(
        contentDigest: { _ in "trusted-digest" },
        moveToTrash: { unknownCalls.append($0.path) }
    )
    try await expectThrows("Cleanup rejects IDs absent from the duplicate results") {
        try await unknownService.removeSelected(groups: [group], selectedIDs: ["stale:item"])
    }
    try check(unknownCalls.snapshot().isEmpty,
              "Unknown selection IDs do not trigger trash operations")
}

private func runArchiveBrowserTests() async throws {
    print("\n[ContentToolsTests] ArchiveBrowserService")
    let root = try makeTempDirectory("archive_browser")
    defer { try? FileManager.default.removeItem(at: root) }
    let archiveURL = root.appendingPathComponent("fixture.zip")
    let nestedPath = "nested/旅行/literal[1]*.txt"
    let selectedBytes = Data("selected payload".utf8)
    try writeZIP([
        ZIPFixtureEntry(path: nestedPath, data: selectedBytes),
        ZIPFixtureEntry(path: "target.txt", data: Data("target".utf8)),
        ZIPFixtureEntry(path: ".hidden", data: Data("hidden".utf8))
    ], to: archiveURL)

    let entries = try await ArchiveBrowserService.index(archiveURL: archiveURL)
    try check(entries.map(\.path).contains(nestedPath),
              "ZIP index preserves nested Unicode paths and literal glob characters")
    try check(entries.contains(where: { $0.path == ".hidden" })
              && !entries.contains(where: { $0.path == "nested" || $0.path == "nested/旅行" }),
              "Hidden members are indexed and missing directory entries remain implicit")
    let apkURL = root.appendingPathComponent("fixture.apk")
    try FileManager.default.copyItem(at: archiveURL, to: apkURL)
    try check(try await ArchiveBrowserService.index(archiveURL: apkURL).count == 3,
              "APK archives use the ZIP member index")

    let output = root.appendingPathComponent("selected-output", isDirectory: true)
    try FileManager.default.createDirectory(at: output, withIntermediateDirectories: false)
    guard let selected = entries.first(where: { $0.path == nestedPath }) else {
        throw TestFailure(description: "Nested selected entry was not indexed")
    }
    let extractedURL = try await ArchiveBrowserService.extract(entry: selected, from: archiveURL, toDirectory: output)
    let extractedBytes = try Data(contentsOf: extractedURL)
    try check(extractedURL.lastPathComponent == "literal[1]*.txt" && extractedBytes == selectedBytes,
              "Extraction writes only the selected member with its literal filename")
    try check(!FileManager.default.fileExists(atPath: output.appendingPathComponent("target.txt").path),
              "Selected-file extraction does not unpack sibling archive members")

    let existing = output.appendingPathComponent("target.txt")
    try Data("preserve".utf8).write(to: existing)
    guard let target = entries.first(where: { $0.path == "target.txt" }) else {
        throw TestFailure(description: "Target entry was not indexed")
    }
    try await expectThrows("Extraction refuses to overwrite an existing destination") {
        _ = try await ArchiveBrowserService.extract(entry: target, from: archiveURL, toDirectory: output)
    }
    try check(try Data(contentsOf: existing) == Data("preserve".utf8),
              "Existing destination contents remain intact after conflict")

    let badCases: [(String, [ZIPFixtureEntry], String)] = [
        ("duplicate members", [ZIPFixtureEntry(path: "dup.txt", data: Data("a".utf8)),
                                ZIPFixtureEntry(path: "dup.txt", data: Data("b".utf8))], "Duplicate paths are rejected"),
        ("parent traversal", [ZIPFixtureEntry(path: "../escape.txt", data: Data("x".utf8))], "Parent traversal members are rejected"),
        ("absolute path", [ZIPFixtureEntry(path: "/absolute.txt", data: Data("x".utf8))], "Absolute members are rejected"),
        ("drive path", [ZIPFixtureEntry(path: "C:/absolute.txt", data: Data("x".utf8))], "Drive-qualified members are rejected"),
        ("symlink", [ZIPFixtureEntry(path: "link", data: Data("target".utf8), symlink: true)], "Symlink members are rejected"),
        ("encrypted", [ZIPFixtureEntry(path: "secret.txt", data: Data("secret".utf8), encrypted: true)], "Encrypted members are rejected"),
        ("oversized", [ZIPFixtureEntry(path: "bomb.bin", data: Data(), declaredSize: UInt32(ArchiveBrowserService.maximumEntrySize + 1))], "Oversized zip-bomb members are rejected")
    ]
    for (filename, fixtureEntries, message) in badCases {
        let badArchive = root.appendingPathComponent("\(filename).zip")
        try writeZIP(fixtureEntries, to: badArchive)
        try await expectThrows(message) {
            _ = try await ArchiveBrowserService.index(archiveURL: badArchive)
        }
    }

    let corruptArchive = root.appendingPathComponent("bad-crc.zip")
    try writeZIP([ZIPFixtureEntry(path: "corrupt.txt", data: Data("corrupt bytes".utf8))],
                 to: corruptArchive, corruptPayloadAt: 0)
    var corruptEntry: ArchiveEntry?
    var corruptRejectedDuringIndex = false
    do {
        corruptEntry = try await ArchiveBrowserService.index(archiveURL: corruptArchive).first
    } catch {
        corruptRejectedDuringIndex = true
        print("  ✓ Corrupt CRC is rejected while indexing or validating archive data")
    }
    try check(corruptRejectedDuringIndex || corruptEntry != nil,
              "CRC fixture reaches either index validation or selected extraction")
    if let corruptEntry {
        let corruptOutput = root.appendingPathComponent("corrupt-output", isDirectory: true)
        try FileManager.default.createDirectory(at: corruptOutput, withIntermediateDirectories: false)
        try await expectThrows("Corrupt CRC is rejected while extracting the selected member") {
            _ = try await ArchiveBrowserService.extract(entry: corruptEntry, from: corruptArchive, toDirectory: corruptOutput)
        }
        try check(!FileManager.default.fileExists(atPath: corruptOutput.appendingPathComponent("corrupt.txt").path),
                  "Failed CRC validation removes its partial output file")
    } else if !corruptRejectedDuringIndex {
        throw TestFailure(description: "Corrupt CRC was not rejected")
    }

    let invalidArchive = root.appendingPathComponent("not-zip.zip")
    try Data("not a zip archive".utf8).write(to: invalidArchive)
    try await expectThrows("Malformed archives fail closed") {
        _ = try await ArchiveBrowserService.index(archiveURL: invalidArchive)
    }
}

@main
private struct ContentToolsTestRunner {
    static func main() async {
        do {
            try await runContentDigestTests()
            try await runExactComparatorTests()
            try await runDuplicateFinderTests()
            try await runDuplicateCleanupTests()
            try await runArchiveBrowserTests()
            print("\n[ContentToolsTests] All content tools checks passed.")
        } catch {
            fputs("❌ [ContentToolsTests] \(error)\n", stderr)
            exit(1)
        }
    }
}
