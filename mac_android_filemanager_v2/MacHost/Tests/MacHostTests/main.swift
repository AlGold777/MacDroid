import Foundation
import MacHostCore

func assertCondition(_ condition: Bool, _ message: String) {
    if !condition {
        print("❌ [FAIL] \(message)")
        exit(1)
    } else {
        print("  ✓ \(message)")
    }
}

print("==================================================")
print("  Running MacDroid Commander System Verification  ")
print("==================================================")

// 1. State Machine Tests
print("\n[TEST 1] State Machine Transitions:")
let sm = JobUnitStateMachine(initialState: .planned)
assertCondition(sm.currentState == .planned, "Initial state is PLANNED")
assertCondition(!sm.transition(to: .completed), "Direct transition PLANNED -> COMPLETED is forbidden")
assertCondition(sm.transition(to: .running), "Transition PLANNED -> RUNNING is valid")
assertCondition(sm.transition(to: .committing), "Transition RUNNING -> COMMITTING is valid")
assertCondition(sm.transition(to: .completed), "Transition COMMITTING -> COMPLETED is valid")

// 2. Intent Ledger Tests
print("\n[TEST 2] Intent Ledger (SQLite WAL):")
let tempDB = FileManager.default.temporaryDirectory.appendingPathComponent("test_ledger_\(UUID().uuidString).db")
defer { try? FileManager.default.removeItem(at: tempDB) }

do {
    let ledger = try IntentLedger(databaseURL: tempDB)
    let itemId = "item_alpha_1"
    let jobId = "job_999"
    let actionId = "act_42"
    let hash = "hash_blake3"
    
    ledger.recordItemState(
        itemId: itemId,
        jobId: jobId,
        actionId: actionId,
        requestHash: hash,
        state: .running,
        bytes: 1024,
        total: 2048,
        mtime: 1700000000
    )
    
    let rec = ledger.getItemRecord(itemId: itemId)
    assertCondition(rec != nil, "Record successfully stored in SQLite")
    assertCondition(rec?.state == .running, "State is RUNNING")
    assertCondition(rec?.bytesTransferred == 1024, "Transferred bytes match (1024)")
    assertCondition(rec?.totalBytes == 2048, "Total bytes match (2048)")
    
    // Перевод в COMMITTING
    ledger.recordItemState(
        itemId: itemId,
        jobId: jobId,
        actionId: actionId,
        requestHash: hash,
        state: .committing,
        bytes: 2048,
        total: 2048,
        mtime: 1700000000
    )
    let rec2 = ledger.getItemRecord(itemId: itemId)
    assertCondition(rec2?.state == .committing, "Updated state is COMMITTING")
} catch {
    assertCondition(false, "IntentLedger error: \(error)")
}

// 3. Unicode NFC Normalization Tests
print("\n[TEST 3] Unicode Canonical NFC Normalization:")
let decomposed = "Документы_Android".decomposedStringWithCanonicalMapping
let item = FileItem(
    id: "id_nfc",
    name: decomposed,
    path: "/storage/" + decomposed,
    size: 100,
    mtime: 0,
    isDirectory: false,
    source: .remotePhone
)
assertCondition(item.name == "Документы_Android".precomposedStringWithCanonicalMapping, "Name canonicalized to NFC")
assertCondition(item.path == "/storage/Документы_Android".precomposedStringWithCanonicalMapping, "Path canonicalized to NFC")

// 4. Local Filesystem Driver Tests
print("\n[TEST 4] Local Filesystem Driver:")
let localFS = LocalFSDriver()
let tempDir = FileManager.default.temporaryDirectory.appendingPathComponent("fs_verify_\(UUID().uuidString)")
try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
defer { try? FileManager.default.removeItem(at: tempDir) }

Task {
    do {
        let testDirName = "Каталог_Проверки"
        let testDirURL = tempDir.appendingPathComponent(testDirName)
        try await localFS.createDirectory(at: testDirURL.path)
        
        let list = try await localFS.listDirectory(at: tempDir.path)
        assertCondition(list.contains(where: { $0.name == testDirName }), "Directory listing contains created folder")
        
        let space = try await localFS.checkFreeSpace(at: tempDir.path)
        assertCondition(space.total > 0, "Free space check reports valid disk capacity")
        
        print("\n🎉 ==================================================")
        print("🎉   ALL TESTS SUCCESSFULLY PASSED!                 ")
        print("🎉 ==================================================")
        exit(0)
    } catch {
        print("❌ Error during async tests: \(error)")
        exit(1)
    }
}

RunLoop.main.run()
