import Foundation
import SQLite3

/// SQLITE_TRANSIENT из sqlite3.h (в Swift не импортируется): SQLite копирует строку при bind,
/// поэтому указатель на временную Swift-строку безопасен только с этим destructor.
private let SQLITE_TRANSIENT = unsafeBitCast(-1, to: sqlite3_destructor_type.self)

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
    /// Общий журнал. Если файл БД не открывается — in-memory журнал (возобновление работает в пределах сессии);
    /// если и он недоступен — журнал без БД: операции возвращают ошибку/nil, передача идёт без возобновления.
    public static let shared: TransferJournal = {
        let fm = FileManager.default
        let appSupport = fm.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
        let dir = appSupport.appendingPathComponent("MacDroidCommander", isDirectory: true)
        try? fm.createDirectory(at: dir, withIntermediateDirectories: true)
        let dbURL = dir.appendingPathComponent("transfer_journal_v1.db")
        if let journal = try? TransferJournal(databaseURL: dbURL) {
            return journal
        }
        print("[TransferJournal] WARNING: файл журнала недоступен (\(dbURL.path)), используется in-memory журнал")
        if let journal = try? TransferJournal(databasePath: ":memory:") {
            return journal
        }
        print("[TransferJournal] ERROR: журнал недоступен, возобновление передач отключено")
        return TransferJournal(unavailable: ())
    }()

    private var db: OpaquePointer?
    private let lock = NSRecursiveLock()

    public convenience init(databaseURL: URL) throws {
        try self.init(databasePath: databaseURL.path)
    }

    private init(databasePath: String) throws {
        var dbPointer: OpaquePointer?
        if sqlite3_open(databasePath, &dbPointer) != SQLITE_OK {
            if let dbPointer = dbPointer { sqlite3_close(dbPointer) }
            throw NSError(domain: "TransferJournal", code: 1, userInfo: [NSLocalizedDescriptionKey: "Unable to open SQLite DB at \(databasePath)"])
        }
        self.db = dbPointer

        executeRaw(sql: "PRAGMA journal_mode = WAL;")
        executeRaw(sql: "PRAGMA synchronous = NORMAL;")

        setupSchema()
    }

    /// Журнал без БД (все запросы безопасно возвращают ошибку или nil).
    private init(unavailable: Void) {
        self.db = nil
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
        
        sqlite3_bind_text(stmt, 1, transferId, -1, SQLITE_TRANSIENT)
        sqlite3_bind_text(stmt, 2, sessionIdentity, -1, SQLITE_TRANSIENT)
        sqlite3_bind_text(stmt, 3, direction, -1, SQLITE_TRANSIENT)
        sqlite3_bind_text(stmt, 4, sourcePath, -1, SQLITE_TRANSIENT)
        sqlite3_bind_int64(stmt, 5, Int64(sourceSize))
        sqlite3_bind_int64(stmt, 6, sourceMtime)
        if let h = sourceHash {
            sqlite3_bind_text(stmt, 7, h, -1, SQLITE_TRANSIENT)
        } else {
            sqlite3_bind_null(stmt, 7)
        }
        sqlite3_bind_text(stmt, 8, targetFinalPath, -1, SQLITE_TRANSIENT)
        sqlite3_bind_text(stmt, 9, targetTempPath, -1, SQLITE_TRANSIENT)
        sqlite3_bind_int64(stmt, 10, Int64(expectedSize))
        sqlite3_bind_int64(stmt, 11, Int64(initialFrontier))
        sqlite3_bind_text(stmt, 12, initialRanges, -1, SQLITE_TRANSIENT)
        sqlite3_bind_text(stmt, 13, state, -1, SQLITE_TRANSIENT)
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
        sqlite3_bind_text(stmt, 2, ranges, -1, SQLITE_TRANSIENT)
        sqlite3_bind_int(stmt, 3, durabilityEvidence ? 1 : 0)
        sqlite3_bind_double(stmt, 4, now)
        sqlite3_bind_text(stmt, 5, transferId, -1, SQLITE_TRANSIENT)
        
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
        
        sqlite3_bind_text(stmt, 1, state, -1, SQLITE_TRANSIENT)
        if let err = errorMessage {
            sqlite3_bind_text(stmt, 2, err, -1, SQLITE_TRANSIENT)
        } else {
            sqlite3_bind_null(stmt, 2)
        }
        sqlite3_bind_double(stmt, 3, now)
        sqlite3_bind_text(stmt, 4, transferId, -1, SQLITE_TRANSIENT)
        
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
        
        sqlite3_bind_text(stmt, 1, transferId, -1, SQLITE_TRANSIENT)
        guard sqlite3_step(stmt) == SQLITE_ROW else { return nil }
        return parseRecord(stmt: stmt!)
    }
    
    /// Ищет незавершённую передачу. Ключ — источник + целевой путь (`targetFinalPath`, если передан):
    /// одинаковый источник, записываемый в другое место, не считается продолжением.
    public func findResumableTransfer(
        sessionIdentity: String,
        sourcePath: String,
        sourceSize: UInt64,
        sourceMtime: Int64,
        direction: String,
        targetFinalPath: String? = nil
    ) -> TransferRecord? {
        lock.lock()
        defer { lock.unlock() }

        let sql = """
        SELECT transfer_id, session_identity, direction, source_path, source_size, source_mtime, source_hash,
               target_final_path, target_temp_path, expected_size, confirmed_frontier, ranges_blob, state,
               durability_evidence, error_message, created_at, updated_at
        FROM transfers
        WHERE session_identity = ? AND source_path = ? AND source_size = ? AND source_mtime = ? AND direction = ?
          AND (? IS NULL OR target_final_path = ?) AND state NOT IN ('completed', 'failed')
        ORDER BY updated_at DESC LIMIT 1;
        """
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return nil }
        defer { sqlite3_finalize(stmt) }

        sqlite3_bind_text(stmt, 1, sessionIdentity, -1, SQLITE_TRANSIENT)
        sqlite3_bind_text(stmt, 2, sourcePath, -1, SQLITE_TRANSIENT)
        sqlite3_bind_int64(stmt, 3, Int64(sourceSize))
        sqlite3_bind_int64(stmt, 4, sourceMtime)
        sqlite3_bind_text(stmt, 5, direction, -1, SQLITE_TRANSIENT)
        if let target = targetFinalPath {
            sqlite3_bind_text(stmt, 6, target, -1, SQLITE_TRANSIENT)
            sqlite3_bind_text(stmt, 7, target, -1, SQLITE_TRANSIENT)
        } else {
            sqlite3_bind_null(stmt, 6)
            sqlite3_bind_null(stmt, 7)
        }

        guard sqlite3_step(stmt) == SQLITE_ROW else { return nil }
        return parseRecord(stmt: stmt!)
    }
    
    /// Candidate locations only. Callers must freshly verify both files before offering cleanup.
    /// A stable device ID permits discovery after an IP/port change; legacy sessions use exact endpoint identity.
    public func copyDoneLocations(deviceID: String?, sessionIdentity: String) -> [CopyDoneLocation] {
        lock.lock()
        defer { lock.unlock() }
        guard db != nil else { return [] }
        let prefix = deviceID.map { $0 + ":" }
        let sql = """
        SELECT DISTINCT source_path, target_final_path FROM transfers
        WHERE direction = 'download' AND state = 'completed'
          AND (session_identity = ? OR (? IS NOT NULL AND substr(session_identity, 1, length(?)) = ?))
        ORDER BY source_path, target_final_path;
        """
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return [] }
        defer { sqlite3_finalize(stmt) }
        sqlite3_bind_text(stmt, 1, sessionIdentity, -1, SQLITE_TRANSIENT)
        for index: Int32 in 2...4 {
            if let prefix { sqlite3_bind_text(stmt, index, prefix, -1, SQLITE_TRANSIENT) }
            else { sqlite3_bind_null(stmt, index) }
        }
        var result: [CopyDoneLocation] = []
        while sqlite3_step(stmt) == SQLITE_ROW {
            guard let phone = sqlite3_column_text(stmt, 0), let mac = sqlite3_column_text(stmt, 1) else { continue }
            result.append(CopyDoneLocation(phonePath: String(cString: phone), macPath: String(cString: mac)))
        }
        return result
    }

    public func deleteTransfer(transferId: String) {
        lock.lock()
        defer { lock.unlock() }
        let sql = "DELETE FROM transfers WHERE transfer_id = ?;"
        var stmt: OpaquePointer?
        if sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK {
            sqlite3_bind_text(stmt, 1, transferId, -1, SQLITE_TRANSIENT)
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
