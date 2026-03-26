import Foundation
import SQLite3

/// Read-only SQLite wrapper for validation purposes
final class SQLiteReader {
    private var db: OpaquePointer?
    let path: String

    init(path: String) throws {
        self.path = path
        guard sqlite3_open_v2(path, &db, SQLITE_OPEN_READONLY, nil) == SQLITE_OK else {
            let msg = db.flatMap { String(cString: sqlite3_errmsg($0)) } ?? "Unknown error"
            throw SQLiteReaderError.openFailed(msg)
        }
    }

    deinit {
        sqlite3_close(db)
    }

    /// Run PRAGMA and return single string result
    func pragma(_ name: String) throws -> String? {
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, "PRAGMA \(name)", -1, &stmt, nil) == SQLITE_OK else {
            throw SQLiteReaderError.queryFailed("PRAGMA \(name)")
        }
        defer { sqlite3_finalize(stmt) }

        if sqlite3_step(stmt) == SQLITE_ROW {
            if let cStr = sqlite3_column_text(stmt, 0) {
                return String(cString: cStr)
            }
        }
        return nil
    }

    /// Run a query and return rows as dictionaries
    func query(_ sql: String) throws -> [[String: Any]] {
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else {
            let msg = db.flatMap { String(cString: sqlite3_errmsg($0)) } ?? "Unknown"
            throw SQLiteReaderError.queryFailed("\(sql): \(msg)")
        }
        defer { sqlite3_finalize(stmt) }

        let columnCount = sqlite3_column_count(stmt)
        var rows: [[String: Any]] = []

        while sqlite3_step(stmt) == SQLITE_ROW {
            var row: [String: Any] = [:]
            for i in 0..<columnCount {
                let name = String(cString: sqlite3_column_name(stmt, i))
                let type = sqlite3_column_type(stmt, i)
                switch type {
                case SQLITE_INTEGER:
                    row[name] = sqlite3_column_int64(stmt, i)
                case SQLITE_FLOAT:
                    row[name] = sqlite3_column_double(stmt, i)
                case SQLITE_TEXT:
                    row[name] = String(cString: sqlite3_column_text(stmt, i))
                case SQLITE_BLOB:
                    let bytes = sqlite3_column_bytes(stmt, i)
                    row[name] = bytes
                case SQLITE_NULL:
                    row[name] = NSNull()
                default:
                    break
                }
            }
            rows.append(row)
        }
        return rows
    }

    /// Get column info via PRAGMA table_info
    func tableColumns(_ table: String) throws -> [(name: String, type: String)] {
        let rows = try query("PRAGMA table_info(\(table))")
        return rows.compactMap { row in
            guard let name = row["name"] as? String,
                  let type = row["type"] as? String else { return nil }
            return (name, type)
        }
    }

    /// Count rows in a table
    func count(_ table: String) throws -> Int {
        let rows = try query("SELECT COUNT(*) as cnt FROM \(table)")
        guard let first = rows.first, let cnt = first["cnt"] as? Int64 else { return 0 }
        return Int(cnt)
    }
}

enum SQLiteReaderError: Error, LocalizedError {
    case openFailed(String)
    case queryFailed(String)

    var errorDescription: String? {
        switch self {
        case .openFailed(let msg): return "SQLite open failed: \(msg)"
        case .queryFailed(let msg): return "SQLite query failed: \(msg)"
        }
    }
}
