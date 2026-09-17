import Foundation
import SQLite3

public struct TransferRecord: Sendable, Equatable {
    public let transferId: String
    public let sessionIdentity: String
    public let direction: String
    public let sourcePath: String
    public let sourceSize: UInt64
    public let sourceMtime: Int64
    public let sourceHash: String?
    public let targetFinalPath: String
    public let targetTempPath: String
    public let expectedSize: UInt64
    public let confirmedFrontier: UInt64
    public let rangesBlob: String
    public let state: String
    public let durabilityEvidence: Bool
    public let errorMessage: String?
    public let createdAt: Double
    public let updatedAt: Double
}

public final class TransferJournal: @unchecked Sendable {
    public static let shared: TransferJournal = {
        let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        let dir = appSupport.appendingPathComponent("MacDroidCommander", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let dbURL = dir.appendingPathComponent("transfer_journal_v1.db")
        return try! TransferJournal(databaseURL: dbURL)
    }()
    
    private var db: OpaquePointer?
    private let lock = NSRecursiveLock()
    
    public init(databaseURL: URL) throws {
        var dbPointer: OpaquePointer?
        if sqlite3_open(databaseURL.path, &dbPointer) != SQLITE_OK {
            throw NSError(domain: "TransferJournal", code: 1, userInfo: [NSLocalizedDescriptionKey: "Unable to open SQLite DB at \(databaseURL.path)"])
        }
        self.db = dbPointer
        
        executeRaw(sql: "PRAGMA journal_mode = WAL;")
        executeRaw(sql: "PRAGMA synchronous = NORMAL;")
        
        setupSchema()
    }
    
    deinit {
        lock.lock()
        defer { lock.unlock() }
        if let db = db {
            sqlite3_close(db)
        }
    }
    
    private func executeRaw(sql: String) {
        lock.lock()
        defer { lock.unlock() }
        var err: UnsafeMutablePointer<CChar>?
        if sqlite3_exec(db, sql, nil, nil, &err) != SQLITE_OK {
            if let err = err {
                print("[TransferJournal] SQL Error: \(String(cString: err))")
                sqlite3_free(err)
            }
        }
    }
    
    private func setupSchema() {
        let sql = """
        CREATE TABLE IF NOT EXISTS transfers (
            transfer_id TEXT PRIMARY KEY,
            session_identity TEXT NOT NULL,
            direction TEXT NOT NULL,
            source_path TEXT NOT NULL,
            source_size INTEGER NOT NULL,
            source_mtime INTEGER NOT NULL,
            source_hash TEXT,
            target_final_path TEXT NOT NULL,
            target_temp_path TEXT NOT NULL,
            expected_size INTEGER NOT NULL,
            confirmed_frontier INTEGER NOT NULL,
            ranges_blob TEXT NOT NULL,
            state TEXT NOT NULL,
            durability_evidence INTEGER NOT NULL DEFAULT 0,
            error_message TEXT,
            created_at REAL NOT NULL,
            updated_at REAL NOT NULL
        );
        CREATE INDEX IF NOT EXISTS idx_transfers_state ON transfers(state);
        CREATE INDEX IF NOT EXISTS idx_transfers_lookup ON transfers(session_identity, source_path, source_size, source_mtime);
        """
        executeRaw(sql: sql)
    }
    
    public func registerTransfer(
        transferId: String,
        sessionIdentity: String,
        direction: String,
        sourcePath: String,
        sourceSize: UInt64,
        sourceMtime: Int64,
        sourceHash: String?,
        targetFinalPath: String,
        targetTempPath: String,
        expectedSize: UInt64,
        initialFrontier: UInt64 = 0,
        initialRanges: String = "",
        state: String = "planned"
    ) throws {
        lock.lock()
        defer { lock.unlock() }
        
        let now = Date().timeIntervalSince1970
        let sql = """
        INSERT INTO transfers (
            transfer_id, session_identity, direction, source_path, source_size, source_mtime, source_hash,
            target_final_path, target_temp_path, expected_size, confirmed_frontier, ranges_blob,
            state, durability_evidence, error_message, created_at, updated_at
        ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, 0, NULL, ?, ?)
        ON CONFLICT(transfer_id) DO UPDATE SET
            state = excluded.state,
            confirmed_frontier = excluded.confirmed_frontier,
            ranges_blob = excluded.ranges_blob,
            updated_at = excluded.updated_at;
        """
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else {
            let msg = String(cString: sqlite3_errmsg(db))
            throw NSError(domain: "TransferJournal", code: 2, userInfo: [NSLocalizedDescriptionKey: "Failed to prepare registerTransfer: \(msg)"])
        }
        defer { sqlite3_finalize(stmt) }
        
        sqlite3_bind_text(stmt, 1, (transferId as NSString).utf8String, -1, nil)
        sqlite3_bind_text(stmt, 2, (sessionIdentity as NSString).utf8String, -1, nil)
        sqlite3_bind_text(stmt, 3, (direction as NSString).utf8String, -1, nil)
        sqlite3_bind_text(stmt, 4, (sourcePath as NSString).utf8String, -1, nil)
        sqlite3_bind_int64(stmt, 5, Int64(sourceSize))
        sqlite3_bind_int64(stmt, 6, sourceMtime)
        if let h = sourceHash {
            sqlite3_bind_text(stmt, 7, (h as NSString).utf8String, -1, nil)
        } else {
            sqlite3_bind_null(stmt, 7)
        }
        sqlite3_bind_text(stmt, 8, (targetFinalPath as NSString).utf8String, -1, nil)
        sqlite3_bind_text(stmt, 9, (targetTempPath as NSString).utf8String, -1, nil)
        sqlite3_bind_int64(stmt, 10, Int64(expectedSize))
        sqlite3_bind_int64(stmt, 11, Int64(initialFrontier))
        sqlite3_bind_text(stmt, 12, (initialRanges as NSString).utf8String, -1, nil)
        sqlite3_bind_text(stmt, 13, (state as NSString).utf8String, -1, nil)
        sqlite3_bind_double(stmt, 14, now)
        sqlite3_bind_double(stmt, 15, now)
        
        guard sqlite3_step(stmt) == SQLITE_DONE else {
            let msg = String(cString: sqlite3_errmsg(db))
            throw NSError(domain: "TransferJournal", code: 3, userInfo: [NSLocalizedDescriptionKey: "Failed to execute registerTransfer: \(msg)"])
        }
    }
    
    public func checkpointProgress(
        transferId: String,
        frontier: UInt64,
        ranges: String,
        durabilityEvidence: Bool
    ) throws {
        lock.lock()
        defer { lock.unlock() }
        
        let now = Date().timeIntervalSince1970
        let sql = """
        UPDATE transfers SET
            confirmed_frontier = ?,
            ranges_blob = ?,
            durability_evidence = ?,
            updated_at = ?
        WHERE transfer_id = ?;
        """
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else {
            let msg = String(cString: sqlite3_errmsg(db))
            throw NSError(domain: "TransferJournal", code: 4, userInfo: [NSLocalizedDescriptionKey: "Failed to prepare checkpointProgress: \(msg)"])
        }
        defer { sqlite3_finalize(stmt) }
        
        sqlite3_bind_int64(stmt, 1, Int64(frontier))
        sqlite3_bind_text(stmt, 2, (ranges as NSString).utf8String, -1, nil)
        sqlite3_bind_int(stmt, 3, durabilityEvidence ? 1 : 0)
        sqlite3_bind_double(stmt, 4, now)
        sqlite3_bind_text(stmt, 5, (transferId as NSString).utf8String, -1, nil)
        
        guard sqlite3_step(stmt) == SQLITE_DONE else {
            let msg = String(cString: sqlite3_errmsg(db))
            throw NSError(domain: "TransferJournal", code: 5, userInfo: [NSLocalizedDescriptionKey: "Failed to execute checkpointProgress: \(msg)"])
        }
    }
    
    public func updateState(
        transferId: String,
        state: String,
        errorMessage: String? = nil
    ) throws {
        lock.lock()
        defer { lock.unlock() }
        
        let now = Date().timeIntervalSince1970
        let sql = """
        UPDATE transfers SET
            state = ?,
            error_message = ?,
            updated_at = ?
        WHERE transfer_id = ?;
        """
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else {
            let msg = String(cString: sqlite3_errmsg(db))
            throw NSError(domain: "TransferJournal", code: 6, userInfo: [NSLocalizedDescriptionKey: "Failed to prepare updateState: \(msg)"])
        }
        defer { sqlite3_finalize(stmt) }
        
        sqlite3_bind_text(stmt, 1, (state as NSString).utf8String, -1, nil)
        if let err = errorMessage {
            sqlite3_bind_text(stmt, 2, (err as NSString).utf8String, -1, nil)
        } else {
            sqlite3_bind_null(stmt, 2)
        }
        sqlite3_bind_double(stmt, 3, now)
        sqlite3_bind_text(stmt, 4, (transferId as NSString).utf8String, -1, nil)
        
        guard sqlite3_step(stmt) == SQLITE_DONE else {
            let msg = String(cString: sqlite3_errmsg(db))
            throw NSError(domain: "TransferJournal", code: 7, userInfo: [NSLocalizedDescriptionKey: "Failed to execute updateState: \(msg)"])
        }
    }
    
    public func getTransfer(transferId: String) -> TransferRecord? {
        lock.lock()
        defer { lock.unlock() }
        
        let sql = "SELECT transfer_id, session_identity, direction, source_path, source_size, source_mtime, source_hash, target_final_path, target_temp_path, expected_size, confirmed_frontier, ranges_blob, state, durability_evidence, error_message, created_at, updated_at FROM transfers WHERE transfer_id = ? LIMIT 1;"
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return nil }
        defer { sqlite3_finalize(stmt) }
        
        sqlite3_bind_text(stmt, 1, (transferId as NSString).utf8String, -1, nil)
        guard sqlite3_step(stmt) == SQLITE_ROW else { return nil }
        return parseRecord(stmt: stmt!)
    }
    
    public func findResumableTransfer(
        sessionIdentity: String,
        sourcePath: String,
        sourceSize: UInt64,
        sourceMtime: Int64,
        direction: String
    ) -> TransferRecord? {
        lock.lock()
        defer { lock.unlock() }
        
        let sql = """
        SELECT transfer_id, session_identity, direction, source_path, source_size, source_mtime, source_hash,
               target_final_path, target_temp_path, expected_size, confirmed_frontier, ranges_blob, state,
               durability_evidence, error_message, created_at, updated_at
        FROM transfers
        WHERE session_identity = ? AND source_path = ? AND source_size = ? AND source_mtime = ? AND direction = ? AND state NOT IN ('completed', 'failed')
        ORDER BY updated_at DESC LIMIT 1;
        """
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return nil }
        defer { sqlite3_finalize(stmt) }
        
        sqlite3_bind_text(stmt, 1, (sessionIdentity as NSString).utf8String, -1, nil)
        sqlite3_bind_text(stmt, 2, (sourcePath as NSString).utf8String, -1, nil)
        sqlite3_bind_int64(stmt, 3, Int64(sourceSize))
        sqlite3_bind_int64(stmt, 4, sourceMtime)
        sqlite3_bind_text(stmt, 5, (direction as NSString).utf8String, -1, nil)
        
        guard sqlite3_step(stmt) == SQLITE_ROW else { return nil }
        return parseRecord(stmt: stmt!)
    }
    
    public func deleteTransfer(transferId: String) {
        lock.lock()
        defer { lock.unlock() }
        let sql = "DELETE FROM transfers WHERE transfer_id = ?;"
        var stmt: OpaquePointer?
        if sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK {
            sqlite3_bind_text(stmt, 1, (transferId as NSString).utf8String, -1, nil)
            _ = sqlite3_step(stmt)
        }
        sqlite3_finalize(stmt)
    }
    
    private func parseRecord(stmt: OpaquePointer) -> TransferRecord {
        let tid = String(cString: sqlite3_column_text(stmt, 0))
        let sid = String(cString: sqlite3_column_text(stmt, 1))
        let dir = String(cString: sqlite3_column_text(stmt, 2))
        let sp = String(cString: sqlite3_column_text(stmt, 3))
        let ss = UInt64(sqlite3_column_int64(stmt, 4))
        let sm = sqlite3_column_int64(stmt, 5)
        let sh: String? = sqlite3_column_text(stmt, 6).map { String(cString: $0) }
        let tfp = String(cString: sqlite3_column_text(stmt, 7))
        let ttp = String(cString: sqlite3_column_text(stmt, 8))
        let es = UInt64(sqlite3_column_int64(stmt, 9))
        let cf = UInt64(sqlite3_column_int64(stmt, 10))
        let rb = String(cString: sqlite3_column_text(stmt, 11))
        let st = String(cString: sqlite3_column_text(stmt, 12))
        let de = sqlite3_column_int(stmt, 13) != 0
        let em: String? = sqlite3_column_text(stmt, 14).map { String(cString: $0) }
        let ca = sqlite3_column_double(stmt, 15)
        let ua = sqlite3_column_double(stmt, 16)
        
        return TransferRecord(
            transferId: tid,
            sessionIdentity: sid,
            direction: dir,
            sourcePath: sp,
            sourceSize: ss,
            sourceMtime: sm,
            sourceHash: sh,
            targetFinalPath: tfp,
            targetTempPath: ttp,
            expectedSize: es,
            confirmedFrontier: cf,
            rangesBlob: rb,
            state: st,
            durabilityEvidence: de,
            errorMessage: em,
            createdAt: ca,
            updatedAt: ua
        )
    }
}
