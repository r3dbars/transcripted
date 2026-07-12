import Foundation
import SQLite3

// MARK: - Shared SQLite Plumbing
//
// TranscriptIndex and EmbeddingStore each own an independent `db:
// OpaquePointer?` sqlite3 connection, so these are free functions that take
// the connection explicitly rather than instance methods on either type.
// Extracted from TranscriptIndex's private SQLite helpers so EmbeddingStore
// can share them instead of re-implementing prepare/bind/step boilerplate.

enum SQLBinding {
    case text(String)
    case int(Int)
    case double(Double)
    case null
}

/// `SQLITE_TRANSIENT` tells sqlite3 to copy bound text/blob data immediately,
/// since the Swift buffers backing it are not guaranteed to outlive the call.
private let sqliteHelperTransient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)

func sqlBind(stmt: OpaquePointer?, index: Int32, value: SQLBinding) {
    switch value {
    case .text(let s):
        sqlite3_bind_text(stmt, index, (s as NSString).utf8String, -1, sqliteHelperTransient)
    case .int(let i):
        sqlite3_bind_int64(stmt, index, Int64(i))
    case .double(let d):
        sqlite3_bind_double(stmt, index, d)
    case .null:
        sqlite3_bind_null(stmt, index)
    }
}

/// Write-path statement execution. Logs and throws on failure so callers can
/// roll back instead of silently committing a half-indexed artifact.
func sqlBindExec(db: OpaquePointer?, sql: String, bindings: [SQLBinding]) throws {
    var stmt: OpaquePointer?
    guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else {
        let message = sqlDBError(db)
        log("SQL prepare failed: \(message) for: \(sql)")
        throw MCPIndexError.queryFailed(message)
    }
    defer { sqlite3_finalize(stmt) }
    for (i, binding) in bindings.enumerated() {
        sqlBind(stmt: stmt, index: Int32(i + 1), value: binding)
    }
    if sqlite3_step(stmt) != SQLITE_DONE {
        let message = sqlDBError(db)
        log("SQL exec failed: \(message) for: \(sql)")
        throw MCPIndexError.queryFailed(message)
    }
}

/// Best-effort execution for setup pragmas and rollback-in-defer, where a
/// failure is logged but must not throw.
func sqlExec(db: OpaquePointer?, sql: String) {
    if sqlite3_exec(db, sql, nil, nil, nil) != SQLITE_OK {
        log("SQL exec failed: \(sqlDBError(db)) for: \(sql)")
    }
}

/// Write-path variant of exec(). Logs and throws on failure — used for
/// BEGIN/COMMIT so a failed transaction boundary aborts the write instead of
/// degrading to per-statement autocommit.
func sqlExecOrThrow(db: OpaquePointer?, sql: String) throws {
    if sqlite3_exec(db, sql, nil, nil, nil) != SQLITE_OK {
        let message = sqlDBError(db)
        log("SQL exec failed: \(message) for: \(sql)")
        throw MCPIndexError.queryFailed(message)
    }
}

func sqlColText(_ stmt: OpaquePointer?, _ col: Int32) -> String {
    guard let ptr = sqlite3_column_text(stmt, col) else { return "" }
    return String(cString: ptr)
}

func sqlColTextOptional(_ stmt: OpaquePointer?, _ col: Int32) -> String? {
    guard sqlite3_column_type(stmt, col) != SQLITE_NULL,
          let ptr = sqlite3_column_text(stmt, col) else { return nil }
    return String(cString: ptr)
}

func sqlDBError(_ db: OpaquePointer?) -> String {
    if let db {
        return String(cString: sqlite3_errmsg(db))
    }
    return "database not open"
}
