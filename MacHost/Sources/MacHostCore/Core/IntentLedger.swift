import Foundation
import SQLite3

private let SQLITE_TRANSIENT = unsafeBitCast(-1, to: sqlite3_destructor_type.self)

public struct ItemRecord: Sendable {
    public let itemId: String
    public let jobId: String
    public let actionId: String
    public let requestHash: String
    public let state: ItemState
    public let bytesTransferred: UInt64
    public let totalBytes: UInt64
    public let mtime: Int64
    public let errorMessage: String?
}

public final class IntentLedger: @unchecked Sendable {
    private var db: OpaquePointer?
    private let lock = NSRecursiveLock()
    
    public init(databaseURL: URL) throws {
        var dbPointer: OpaquePointer?
        if sqlite3_open(databaseURL.path, &dbPointer) != SQLITE_OK {
            throw NSError(domain: "IntentLedger", code: 1, userInfo: [NSLocalizedDescriptionKey: "Unable to open SQLite DB at \(databaseURL.path)"])
        }
        self.db = dbPointer
        
        // WAL режим и синхронизация NORMAL для максимальной отказоустойчивости и скорости
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
    
    private func setupSchema() {
        let sql = """
        CREATE TABLE IF NOT EXISTS item_intents (
            item_id TEXT PRIMARY KEY,
            job_id TEXT NOT NULL,
            action_id TEXT NOT NULL,
            request_hash TEXT NOT NULL,
            state TEXT NOT NULL,
            bytes_transferred INTEGER NOT NULL,
            total_bytes INTEGER NOT NULL,
            mtime INTEGER NOT NULL,
            error_message TEXT,
            updated_at REAL NOT NULL
        );
        CREATE INDEX IF NOT EXISTS idx_intents_job ON item_intents(job_id);
        CREATE INDEX IF NOT EXISTS idx_intents_state ON item_intents(state);
        """
        executeRaw(sql: sql)
    }
    
    // PRF-01: Транзакционные методы для пакетной обработки тысяч файлов без I/O оверхеда
    // Все транзакционные вызовы берут тот же lock, что и запись состояний (BEGIN/COMMIT не должны
    // перемежаться с записями из других потоков).
    public func beginTransaction() {
        lock.lock()
        defer { lock.unlock() }
        if !executeRaw(sql: "BEGIN IMMEDIATE TRANSACTION;") {
            print("[IntentLedger] ERROR: BEGIN IMMEDIATE не выполнен")
        }
    }

    public func commitTransaction() {
        lock.lock()
        defer { lock.unlock() }
        if !executeRaw(sql: "COMMIT TRANSACTION;") {
            print("[IntentLedger] ERROR: COMMIT не выполнен")
        }
    }

    public func rollbackTransaction() {
        lock.lock()
        defer { lock.unlock() }
        if !executeRaw(sql: "ROLLBACK TRANSACTION;") {
            print("[IntentLedger] ERROR: ROLLBACK не выполнен")
        }
    }

    public func withTransaction<T>(_ block: () throws -> T) throws -> T {
        lock.lock()
        defer { lock.unlock() }

        guard executeRaw(sql: "BEGIN IMMEDIATE TRANSACTION;") else {
            throw NSError(domain: "IntentLedger", code: 2, userInfo: [NSLocalizedDescriptionKey: "Не удалось начать транзакцию журнала"])
        }
        do {
            let result = try block()
            guard executeRaw(sql: "COMMIT TRANSACTION;") else {
                _ = executeRaw(sql: "ROLLBACK TRANSACTION;")
                throw NSError(domain: "IntentLedger", code: 3, userInfo: [NSLocalizedDescriptionKey: "Не удалось зафиксировать транзакцию журнала"])
            }
            return result
        } catch {
            _ = executeRaw(sql: "ROLLBACK TRANSACTION;")
            throw error
        }
    }
    
    public func recordItemState(
        itemId: String,
        jobId: String,
        actionId: String,
        requestHash: String,
        state: ItemState,
        bytes: UInt64,
        total: UInt64,
        mtime: Int64,
        error: String? = nil
    ) {
        lock.lock()
        defer { lock.unlock() }
        
        let sql = """
        INSERT INTO item_intents (
            item_id, job_id, action_id, request_hash, state,
            bytes_transferred, total_bytes, mtime, error_message, updated_at
        ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
        ON CONFLICT(item_id) DO UPDATE SET
            state = excluded.state,
            bytes_transferred = excluded.bytes_transferred,
            total_bytes = excluded.total_bytes,
            error_message = excluded.error_message,
            updated_at = excluded.updated_at;
        """
        
        var stmt: OpaquePointer?
        if sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK {
            sqlite3_bind_text(stmt, 1, itemId, -1, SQLITE_TRANSIENT)
            sqlite3_bind_text(stmt, 2, jobId, -1, SQLITE_TRANSIENT)
            sqlite3_bind_text(stmt, 3, actionId, -1, SQLITE_TRANSIENT)
            sqlite3_bind_text(stmt, 4, requestHash, -1, SQLITE_TRANSIENT)
            sqlite3_bind_text(stmt, 5, state.rawValue, -1, SQLITE_TRANSIENT)
            sqlite3_bind_int64(stmt, 6, Int64(bytes))
            sqlite3_bind_int64(stmt, 7, Int64(total))
            sqlite3_bind_int64(stmt, 8, mtime)
            
            if let err = error {
                sqlite3_bind_text(stmt, 9, err, -1, SQLITE_TRANSIENT)
            } else {
                sqlite3_bind_null(stmt, 9)
            }
            
            sqlite3_bind_double(stmt, 10, Date().timeIntervalSince1970)
            
            let stepResult = sqlite3_step(stmt)
            if stepResult != SQLITE_DONE {
                let errMsg = String(cString: sqlite3_errmsg(db))
                print("[IntentLedger] ERROR: Failed to record item state (\(stepResult)): \(errMsg)")
            }
        } else {
            let errMsg = String(cString: sqlite3_errmsg(db))
            print("[IntentLedger] ERROR: Failed to prepare statement: \(errMsg)")
        }
        sqlite3_finalize(stmt)
    }
    
    public func getItemRecord(itemId: String) -> ItemRecord? {
        lock.lock()
        defer { lock.unlock() }
        
        let sql = "SELECT item_id, job_id, action_id, request_hash, state, bytes_transferred, total_bytes, mtime, error_message FROM item_intents WHERE item_id = ?;"
        var stmt: OpaquePointer?
        var record: ItemRecord? = nil
        
        if sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK {
            sqlite3_bind_text(stmt, 1, itemId, -1, SQLITE_TRANSIENT)
            
            if sqlite3_step(stmt) == SQLITE_ROW {
                let id = String(cString: sqlite3_column_text(stmt, 0))
                let jId = String(cString: sqlite3_column_text(stmt, 1))
                let aId = String(cString: sqlite3_column_text(stmt, 2))
                let rHash = String(cString: sqlite3_column_text(stmt, 3))
                let rawState = String(cString: sqlite3_column_text(stmt, 4))
                let bytes = UInt64(sqlite3_column_int64(stmt, 5))
                let total = UInt64(sqlite3_column_int64(stmt, 6))
                let mtime = sqlite3_column_int64(stmt, 7)
                
                var errMsg: String? = nil
                if let errText = sqlite3_column_text(stmt, 8) {
                    errMsg = String(cString: errText)
                }
                
                let state = ItemState(rawValue: rawState) ?? .failed
                record = ItemRecord(
                    itemId: id,
                    jobId: jId,
                    actionId: aId,
                    requestHash: rHash,
                    state: state,
                    bytesTransferred: bytes,
                    totalBytes: total,
                    mtime: mtime,
                    errorMessage: errMsg
                )
            }
        }
        sqlite3_finalize(stmt)
        return record
    }
    
    /// Выполняет SQL без результата. Возвращает false при ошибке (вызывающий решает, что делать).
    @discardableResult
    private func executeRaw(sql: String) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        var err: UnsafeMutablePointer<CChar>?
        let rc = sqlite3_exec(db, sql, nil, nil, &err)
        if let err = err {
            print("SQLite raw exec warning: \(String(cString: err))")
            sqlite3_free(err)
        }
        return rc == SQLITE_OK
    }
}
