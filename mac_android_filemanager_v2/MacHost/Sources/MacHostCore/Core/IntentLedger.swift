import Foundation
import SQLite3

public struct JobItemRecord: Sendable {
    public let itemId: String
    public let jobId: String
    public let actionId: String
    public let requestHash: String
    public let state: ItemState
    public let bytesTransferred: UInt64
    public let totalBytes: UInt64
    public let sourceMtime: Int64
    public let errorMessage: String?
    public let updatedAt: Int64
}

public final class IntentLedger: @unchecked Sendable {
    private var db: OpaquePointer?
    private let lock = NSLock()
    
    public init(databaseURL: URL) throws {
        if sqlite3_open(databaseURL.path, &db) != SQLITE_OK {
            throw NSError(domain: "IntentLedger", code: 1, userInfo: [NSLocalizedDescriptionKey: "Failed to open SQLite database at \(databaseURL.path)"])
        }
        try setupSchema()
    }
    
    deinit {
        if let db = db {
            sqlite3_close(db)
        }
    }
    
    private func setupSchema() throws {
        let sql = """
        PRAGMA journal_mode=WAL;
        PRAGMA synchronous=NORMAL;
        
        CREATE TABLE IF NOT EXISTS jobs (
            job_id TEXT PRIMARY KEY,
            operation_type TEXT NOT NULL,
            source_path TEXT NOT NULL,
            dest_path TEXT NOT NULL,
            status TEXT NOT NULL,
            created_at INTEGER NOT NULL
        );
        
        CREATE TABLE IF NOT EXISTS job_items (
            item_id TEXT PRIMARY KEY,
            job_id TEXT NOT NULL,
            action_id TEXT NOT NULL,
            request_hash TEXT NOT NULL,
            state TEXT NOT NULL,
            bytes_transferred INTEGER NOT NULL,
            total_bytes INTEGER NOT NULL,
            source_mtime INTEGER NOT NULL,
            error_message TEXT,
            updated_at INTEGER NOT NULL
        );
        
        CREATE INDEX IF NOT EXISTS idx_job_items_job_id ON job_items(job_id);
        CREATE INDEX IF NOT EXISTS idx_job_items_state ON job_items(state);
        """
        
        lock.lock()
        defer { lock.unlock() }
        
        if sqlite3_exec(db, sql, nil, nil, nil) != SQLITE_OK {
            let errmsg = String(cString: sqlite3_errmsg(db))
            throw NSError(domain: "IntentLedger", code: 2, userInfo: [NSLocalizedDescriptionKey: "Failed to setup schema: \(errmsg)"])
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
        
        let sql = "INSERT OR REPLACE INTO job_items VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?);"
        var stmt: OpaquePointer?
        if sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK {
            sqlite3_bind_text(stmt, 1, (itemId as NSString).utf8String, -1, nil)
            sqlite3_bind_text(stmt, 2, (jobId as NSString).utf8String, -1, nil)
            sqlite3_bind_text(stmt, 3, (actionId as NSString).utf8String, -1, nil)
            sqlite3_bind_text(stmt, 4, (requestHash as NSString).utf8String, -1, nil)
            sqlite3_bind_text(stmt, 5, (state.rawValue as NSString).utf8String, -1, nil)
            sqlite3_bind_int64(stmt, 6, Int64(bytes))
            sqlite3_bind_int64(stmt, 7, Int64(total))
            sqlite3_bind_int64(stmt, 8, mtime)
            if let error = error {
                sqlite3_bind_text(stmt, 9, (error as NSString).utf8String, -1, nil)
            } else {
                sqlite3_bind_null(stmt, 9)
            }
            sqlite3_bind_int64(stmt, 10, Int64(Date().timeIntervalSince1970 * 1000))
            sqlite3_step(stmt)
        }
        sqlite3_finalize(stmt)
    }
    
    public func getItemRecord(itemId: String) -> JobItemRecord? {
        lock.lock()
        defer { lock.unlock() }
        
        let sql = "SELECT item_id, job_id, action_id, request_hash, state, bytes_transferred, total_bytes, source_mtime, error_message, updated_at FROM job_items WHERE item_id = ?;"
        var stmt: OpaquePointer?
        defer { sqlite3_finalize(stmt) }
        
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return nil }
        sqlite3_bind_text(stmt, 1, (itemId as NSString).utf8String, -1, nil)
        
        if sqlite3_step(stmt) == SQLITE_ROW {
            let iId = String(cString: sqlite3_column_text(stmt, 0))
            let jId = String(cString: sqlite3_column_text(stmt, 1))
            let aId = String(cString: sqlite3_column_text(stmt, 2))
            let rHash = String(cString: sqlite3_column_text(stmt, 3))
            let stateStr = String(cString: sqlite3_column_text(stmt, 4))
            let bytes = UInt64(sqlite3_column_int64(stmt, 5))
            let total = UInt64(sqlite3_column_int64(stmt, 6))
            let mtime = sqlite3_column_int64(stmt, 7)
            let errStr = sqlite3_column_text(stmt, 8).map { String(cString: $0) }
            let updAt = sqlite3_column_int64(stmt, 9)
            
            let state = ItemState(rawValue: stateStr) ?? .indeterminate
            return JobItemRecord(
                itemId: iId,
                jobId: jId,
                actionId: aId,
                requestHash: rHash,
                state: state,
                bytesTransferred: bytes,
                totalBytes: total,
                sourceMtime: mtime,
                errorMessage: errStr,
                updatedAt: updAt
            )
        }
        return nil
    }
}
