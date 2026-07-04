import Foundation
import SQLite3

struct TimelineScreenshotRow: Equatable {
    let id: Int64
    let capturedAt: Int64
    let filePath: String
    let fileSize: Int64
    let idleSecondsAtCapture: Double
    let appBundleID: String?
    let appName: String?
    let windowTitle: String?
    let displayID: Int64?
    let isDeleted: Bool
}

struct NewTimelineScreenshot {
    let capturedAt: Int64
    let filePath: String
    let fileSize: Int64
    let idleSecondsAtCapture: Double
    let appBundleID: String?
    let appName: String?
    let windowTitle: String?
    let displayID: Int64?

    init(
        capturedAt: Int64,
        filePath: String,
        fileSize: Int64,
        idleSecondsAtCapture: Double,
        appBundleID: String? = nil,
        appName: String? = nil,
        windowTitle: String? = nil,
        displayID: Int64? = nil
    ) {
        self.capturedAt = capturedAt
        self.filePath = filePath
        self.fileSize = fileSize
        self.idleSecondsAtCapture = idleSecondsAtCapture
        self.appBundleID = appBundleID
        self.appName = appName
        self.windowTitle = windowTitle
        self.displayID = displayID
    }
}

enum TimelineDatabaseError: Error, CustomStringConvertible {
    case openFailed(String)
    case prepareFailed(String)
    case executeFailed(String)
    case closed

    var description: String {
        switch self {
        case .openFailed(let message): "open failed: \(message)"
        case .prepareFailed(let message): "prepare failed: \(message)"
        case .executeFailed(let message): "execute failed: \(message)"
        case .closed: "database is closed"
        }
    }
}

final class TimelineDatabase {
    static let currentSchemaVersion = 1

    private let databaseURL: URL
    private let fileManager: FileManager
    private let queue = DispatchQueue(label: "com.transcripted.timelinedb", qos: .utility)
    private var db: OpaquePointer?
    private let sqliteTransient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)

    init(databaseURL: URL = FileManager.default.transcriptedTimelineDatabaseURL, fileManager: FileManager = .default) throws {
        self.databaseURL = databaseURL
        self.fileManager = fileManager
        try fileManager.createPrivateDirectory(at: databaseURL.deletingLastPathComponent())
        try open()
        try queue.sync {
            try migrateIfNeeded()
        }
    }

    deinit {
        queue.sync {
            if let db {
                sqlite3_close(db)
            }
            db = nil
        }
    }

    func schemaVersion() throws -> Int {
        try queue.sync {
            try intValue("SELECT COALESCE(MAX(version), 0) FROM timeline_schema_migrations;")
        }
    }

    func journalMode() throws -> String {
        try queue.sync {
            try stringValue("PRAGMA journal_mode;") ?? ""
        }
    }

    func insertScreenshot(_ screenshot: NewTimelineScreenshot) throws -> Int64 {
        try queue.sync {
            let sql = """
            INSERT INTO screenshots (
                captured_at, file_path, file_size, idle_seconds_at_capture,
                app_bundle_id, app_name, window_title, display_id
            ) VALUES (?, ?, ?, ?, ?, ?, ?, ?);
            """
            let statement = try prepare(sql)
            defer { sqlite3_finalize(statement) }
            sqlite3_bind_int64(statement, 1, screenshot.capturedAt)
            bindText(screenshot.filePath, to: statement, index: 2)
            sqlite3_bind_int64(statement, 3, screenshot.fileSize)
            sqlite3_bind_double(statement, 4, screenshot.idleSecondsAtCapture)
            bindText(screenshot.appBundleID, to: statement, index: 5)
            bindText(screenshot.appName, to: statement, index: 6)
            bindText(screenshot.windowTitle, to: statement, index: 7)
            bindInt64(screenshot.displayID, to: statement, index: 8)
            try stepDone(statement)
            fileManager.restrictSQLiteArtifactsToOwnerOnly(at: databaseURL)
            return sqlite3_last_insert_rowid(db)
        }
    }

    func insertAnalysisBatch(
        start: Int64,
        end: Int64,
        status: String,
        screenshotIDs: [Int64],
        failureReason: String? = nil,
        provider: String? = nil,
        createdAt: Int64? = nil
    ) throws -> Int64 {
        try queue.sync {
            try transaction {
                let sql = """
                INSERT INTO analysis_batches (
                    batch_start_ts, batch_end_ts, status, failure_reason, provider, created_at
                ) VALUES (?, ?, ?, ?, ?, ?);
                """
                let statement = try prepare(sql)
                defer { sqlite3_finalize(statement) }
                sqlite3_bind_int64(statement, 1, start)
                sqlite3_bind_int64(statement, 2, end)
                bindText(status, to: statement, index: 3)
                bindText(failureReason, to: statement, index: 4)
                bindText(provider, to: statement, index: 5)
                sqlite3_bind_int64(statement, 6, createdAt ?? Int64(Date().timeIntervalSince1970))
                try stepDone(statement)
                let batchID = sqlite3_last_insert_rowid(db)
                for screenshotID in screenshotIDs {
                    let link = try prepare("INSERT OR IGNORE INTO batch_screenshots (batch_id, screenshot_id) VALUES (?, ?);")
                    defer { sqlite3_finalize(link) }
                    sqlite3_bind_int64(link, 1, batchID)
                    sqlite3_bind_int64(link, 2, screenshotID)
                    try stepDone(link)
                }
                return batchID
            }
        }
    }

    func screenshots(includeDeleted: Bool = false) throws -> [TimelineScreenshotRow] {
        try queue.sync {
            let whereClause = includeDeleted ? "" : " WHERE is_deleted = 0"
            return try screenshotRows("SELECT * FROM screenshots\(whereClause) ORDER BY captured_at ASC, id ASC;")
        }
    }

    func screenshotRelativePaths(includeDeleted: Bool = false) throws -> Set<String> {
        try Set(screenshots(includeDeleted: includeDeleted).map(\.filePath))
    }

    func oldestPurgeCandidates(limit: Int) throws -> [TimelineScreenshotRow] {
        guard limit > 0 else { return [] }
        return try queue.sync {
            let sql = """
            SELECT s.* FROM screenshots s
            WHERE s.is_deleted = 0
              AND NOT EXISTS (
                SELECT 1
                FROM batch_screenshots bs
                JOIN analysis_batches ab ON ab.id = bs.batch_id
                WHERE bs.screenshot_id = s.id
                  AND ab.status = 'processing'
              )
            ORDER BY s.captured_at ASC, s.id ASC
            LIMIT ?;
            """
            let statement = try prepare(sql)
            defer { sqlite3_finalize(statement) }
            sqlite3_bind_int(statement, 1, Int32(limit))
            return try screenshotRows(from: statement)
        }
    }

    func markScreenshotsDeleted(ids: [Int64]) throws {
        guard !ids.isEmpty else { return }
        try queue.sync {
            try transaction {
                let statement = try prepare("UPDATE screenshots SET is_deleted = 1 WHERE id = ?;")
                defer { sqlite3_finalize(statement) }
                for id in ids {
                    sqlite3_reset(statement)
                    sqlite3_clear_bindings(statement)
                    sqlite3_bind_int64(statement, 1, id)
                    try stepDone(statement)
                }
            }
        }
    }

    func hardDeleteScreenshots(ids: [Int64]) throws {
        guard !ids.isEmpty else { return }
        try queue.sync {
            try transaction {
                let statement = try prepare("DELETE FROM screenshots WHERE id = ?;")
                defer { sqlite3_finalize(statement) }
                for id in ids {
                    sqlite3_reset(statement)
                    sqlite3_clear_bindings(statement)
                    sqlite3_bind_int64(statement, 1, id)
                    try stepDone(statement)
                }
            }
        }
    }

    func checkpointWAL() throws {
        try queue.sync {
            try execute("PRAGMA wal_checkpoint(TRUNCATE);")
            fileManager.restrictSQLiteArtifactsToOwnerOnly(at: databaseURL)
        }
    }

    private func open() throws {
        if sqlite3_open(databaseURL.path, &db) != SQLITE_OK {
            let message = db.map { String(cString: sqlite3_errmsg($0)) } ?? "unknown"
            throw TimelineDatabaseError.openFailed(message)
        }

        fileManager.restrictSQLiteArtifactsToOwnerOnly(at: databaseURL)
        try execute("PRAGMA journal_mode=WAL;")
        try execute("PRAGMA busy_timeout=5000;")
        try execute("PRAGMA synchronous=NORMAL;")
        fileManager.restrictSQLiteArtifactsToOwnerOnly(at: databaseURL)
    }

    private func migrateIfNeeded() throws {
        try execute("""
        CREATE TABLE IF NOT EXISTS timeline_schema_migrations (
            version INTEGER PRIMARY KEY,
            applied_at INTEGER NOT NULL
        );
        """)

        let applied = try schemaVersionUnlocked()
        if applied < 1 {
            try transaction {
                try applyInitialSchema()
                try execute(
                    "INSERT OR IGNORE INTO timeline_schema_migrations (version, applied_at) VALUES (1, strftime('%s','now'));"
                )
            }
        }
        fileManager.restrictSQLiteArtifactsToOwnerOnly(at: databaseURL)
    }

    private func applyInitialSchema() throws {
        try execute("""
        CREATE TABLE IF NOT EXISTS screenshots (
            id INTEGER PRIMARY KEY,
            captured_at INTEGER NOT NULL,
            file_path TEXT NOT NULL,
            file_size INTEGER NOT NULL,
            idle_seconds_at_capture REAL NOT NULL,
            app_bundle_id TEXT,
            app_name TEXT,
            window_title TEXT,
            display_id INTEGER,
            is_deleted INTEGER NOT NULL DEFAULT 0
        );
        """)
        try execute("CREATE INDEX IF NOT EXISTS idx_screenshots_captured ON screenshots(captured_at);")
        try execute("""
        CREATE TABLE IF NOT EXISTS analysis_batches (
            id INTEGER PRIMARY KEY,
            batch_start_ts INTEGER NOT NULL,
            batch_end_ts INTEGER NOT NULL,
            status TEXT NOT NULL,
            failure_reason TEXT,
            provider TEXT,
            created_at INTEGER NOT NULL
        );
        """)
        try execute("""
        CREATE TABLE IF NOT EXISTS batch_screenshots (
            batch_id INTEGER,
            screenshot_id INTEGER,
            PRIMARY KEY(batch_id, screenshot_id)
        );
        """)
        try execute("""
        CREATE TABLE IF NOT EXISTS observations (
            id INTEGER PRIMARY KEY,
            batch_id INTEGER NOT NULL,
            start_ts INTEGER NOT NULL,
            end_ts INTEGER NOT NULL,
            observation TEXT NOT NULL,
            llm_model TEXT
        );
        """)
        try execute("""
        CREATE TABLE IF NOT EXISTS timeline_cards (
            id INTEGER PRIMARY KEY,
            batch_id INTEGER,
            day TEXT NOT NULL,
            start_ts INTEGER NOT NULL,
            end_ts INTEGER NOT NULL,
            kind TEXT NOT NULL DEFAULT 'activity',
            capture_id TEXT,
            title TEXT NOT NULL,
            summary TEXT NOT NULL,
            detailed_summary TEXT,
            category TEXT NOT NULL,
            subcategory TEXT,
            app_sites_json TEXT,
            distractions_json TEXT,
            is_deleted INTEGER NOT NULL DEFAULT 0
        );
        """)
        try execute("CREATE INDEX IF NOT EXISTS idx_cards_day ON timeline_cards(day);")
        try execute("""
        CREATE TABLE IF NOT EXISTS llm_calls (
            id INTEGER PRIMARY KEY,
            batch_id INTEGER,
            provider TEXT,
            model TEXT,
            operation TEXT,
            status TEXT,
            latency_ms INTEGER,
            created_at INTEGER,
            request_body TEXT,
            response_body TEXT
        );
        """)
        try execute("""
        CREATE TABLE IF NOT EXISTS chat_conversations (
            id INTEGER PRIMARY KEY,
            day TEXT,
            title TEXT,
            created_at INTEGER
        );
        """)
        try execute("""
        CREATE TABLE IF NOT EXISTS chat_messages (
            id INTEGER PRIMARY KEY,
            conversation_id INTEGER,
            role TEXT,
            content TEXT,
            tool_calls_json TEXT,
            created_at INTEGER
        );
        """)
    }

    private func schemaVersionUnlocked() throws -> Int {
        try intValue("SELECT COALESCE(MAX(version), 0) FROM timeline_schema_migrations;")
    }

    private func transaction<T>(_ block: () throws -> T) throws -> T {
        try execute("BEGIN IMMEDIATE;")
        do {
            let value = try block()
            try execute("COMMIT;")
            return value
        } catch {
            try? execute("ROLLBACK;")
            throw error
        }
    }

    private func screenshotRows(_ sql: String) throws -> [TimelineScreenshotRow] {
        let statement = try prepare(sql)
        defer { sqlite3_finalize(statement) }
        return try screenshotRows(from: statement)
    }

    private func screenshotRows(from statement: OpaquePointer?) throws -> [TimelineScreenshotRow] {
        var rows: [TimelineScreenshotRow] = []
        while sqlite3_step(statement) == SQLITE_ROW {
            rows.append(TimelineScreenshotRow(
                id: sqlite3_column_int64(statement, 0),
                capturedAt: sqlite3_column_int64(statement, 1),
                filePath: textColumn(statement, 2) ?? "",
                fileSize: sqlite3_column_int64(statement, 3),
                idleSecondsAtCapture: sqlite3_column_double(statement, 4),
                appBundleID: textColumn(statement, 5),
                appName: textColumn(statement, 6),
                windowTitle: textColumn(statement, 7),
                displayID: sqlite3_column_type(statement, 8) == SQLITE_NULL ? nil : sqlite3_column_int64(statement, 8),
                isDeleted: sqlite3_column_int(statement, 9) != 0
            ))
        }
        return rows
    }

    private func intValue(_ sql: String) throws -> Int {
        let statement = try prepare(sql)
        defer { sqlite3_finalize(statement) }
        if sqlite3_step(statement) == SQLITE_ROW {
            return Int(sqlite3_column_int(statement, 0))
        }
        return 0
    }

    private func stringValue(_ sql: String) throws -> String? {
        let statement = try prepare(sql)
        defer { sqlite3_finalize(statement) }
        if sqlite3_step(statement) == SQLITE_ROW {
            return textColumn(statement, 0)
        }
        return nil
    }

    private func prepare(_ sql: String) throws -> OpaquePointer? {
        guard let db else { throw TimelineDatabaseError.closed }
        var statement: OpaquePointer?
        if sqlite3_prepare_v2(db, sql, -1, &statement, nil) != SQLITE_OK {
            throw TimelineDatabaseError.prepareFailed(errorMessage())
        }
        return statement
    }

    private func execute(_ sql: String) throws {
        guard let db else { throw TimelineDatabaseError.closed }
        var error: UnsafeMutablePointer<CChar>?
        if sqlite3_exec(db, sql, nil, nil, &error) != SQLITE_OK {
            let message = error.map { String(cString: $0) } ?? errorMessage()
            sqlite3_free(error)
            throw TimelineDatabaseError.executeFailed(message)
        }
    }

    private func stepDone(_ statement: OpaquePointer?) throws {
        if sqlite3_step(statement) != SQLITE_DONE {
            throw TimelineDatabaseError.executeFailed(errorMessage())
        }
    }

    private func bindText(_ value: String?, to statement: OpaquePointer?, index: Int32) {
        guard let value else {
            sqlite3_bind_null(statement, index)
            return
        }
        sqlite3_bind_text(statement, index, (value as NSString).utf8String, -1, sqliteTransient)
    }

    private func bindInt64(_ value: Int64?, to statement: OpaquePointer?, index: Int32) {
        guard let value else {
            sqlite3_bind_null(statement, index)
            return
        }
        sqlite3_bind_int64(statement, index, value)
    }

    private func textColumn(_ statement: OpaquePointer?, _ index: Int32) -> String? {
        sqlite3_column_text(statement, index).map { String(cString: $0) }
    }

    private func errorMessage() -> String {
        db.map { String(cString: sqlite3_errmsg($0)) } ?? "database not open"
    }
}
