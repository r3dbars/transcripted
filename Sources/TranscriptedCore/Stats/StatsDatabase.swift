import Foundation
import SQLite3

/// SQLite database for persistent stats tracking
/// Stores recording history, action items, and daily activity for the dashboard
@available(macOS 14.0, *)
public final class StatsDatabase {

    public static let shared = StatsDatabase()

    var db: OpaquePointer?
    var isDatabaseOpen = false
    let dbPath: URL

    /// Serial queue ensuring thread-safe database access
    /// All database operations are serialized through this queue
    let queue = DispatchQueue(label: "com.transcripted.statsdb", qos: .utility)

    /// Cached formatter for parsing date+time columns stored as "yyyy-MM-dd HH:mm:ss".
    /// DateFormatter is expensive to allocate; reuse across all row parses on the serial queue.
    private static let rowDateFormatter: DateFormatter = {
        let fmt = DateFormatter()
        fmt.dateFormat = "yyyy-MM-dd HH:mm:ss"
        fmt.locale = Locale(identifier: "en_US_POSIX")
        return fmt
    }()

    /// SQLITE_TRANSIENT tells SQLite to copy text immediately, preventing dangling pointer issues
    /// from temporary (NSString).utf8String pointers
    let SQLITE_TRANSIENT = unsafeBitCast(-1, to: sqlite3_destructor_type.self)

    private init() {
        let paths = CoreStoragePaths.default
        try? FileManager.default.createDirectory(
            at: paths.statsDB.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        dbPath = paths.statsDB
        // Security: run database setup on the serial queue so that isDatabaseOpen is set
        // within the same queue context that all public methods use. This establishes a
        // memory barrier preventing public methods from observing a stale isDatabaseOpen=false
        // if init and a concurrent public-method call race on the same instance.
        queue.sync {
            openDatabase()
            createTables()
        }
    }

    /// Public initializer that accepts a custom SQLite path.
    /// Used by tests and by embedders (e.g. the app in this repo) that want to store the stats
    /// database outside the default `CoreStoragePaths.default` layout.
    public init(path: String) {
        dbPath = URL(fileURLWithPath: path)
        try? FileManager.default.createDirectory(
            at: dbPath.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        // Security: same queue.sync pattern as private init() — see comment there.
        queue.sync {
            openDatabase()
            createTables()
        }
    }

    deinit {
        sqlite3_close(db)
    }

    // MARK: - Database Setup

    private func openDatabase() {
        if sqlite3_open(dbPath.path, &db) != SQLITE_OK {
            let sqliteError = db.map { String(cString: sqlite3_errmsg($0)) } ?? "unknown"
            AppLogger.stats.error("Failed to open stats database", ["path": dbPath.path, "sqlite_error": sqliteError])
            isDatabaseOpen = false
        } else {
            configureOpenDatabase()

            // Corruption detection: run quick_check to verify database integrity
            if !verifyDatabaseIntegrity() {
                AppLogger.stats.error("CRITICAL: Stats database corrupt — backing up and recreating", ["path": dbPath.path])
                sqlite3_close(db)
                db = nil
                // Backup corrupt file with timestamp
                let backupName = "stats_corrupt_\(DateFormattingHelper.formatFilename(Date())).sqlite"
                let backupPath = dbPath.deletingLastPathComponent().appendingPathComponent(backupName)
                try? FileManager.default.moveItem(at: dbPath, to: backupPath)
                // Recreate fresh database
                if sqlite3_open(dbPath.path, &db) == SQLITE_OK {
                    configureOpenDatabase()
                    AppLogger.stats.info("Recreated fresh database after corruption recovery")
                } else {
                    isDatabaseOpen = false
                    AppLogger.stats.error("Failed to recreate database after corruption recovery")
                }
            } else {
                AppLogger.stats.info("Opened database", ["path": dbPath.path])
            }
        }
    }

    /// Apply permissions and WAL pragmas to an already-opened database handle.
    /// Called on both initial open and corruption-recovery re-open.
    private func configureOpenDatabase() {
        isDatabaseOpen = true
        FileManager.default.restrictSQLiteArtifactsToOwnerOnly(atPath: dbPath.path)
        // Security: check each PRAGMA return value so a silent failure (e.g. WAL mode refused
        // because another process holds the db) is logged rather than silently misconfiguring
        // the database. Matches the same pattern used in SpeakerDatabase.configureOpenDatabase().
        let pragmas = [
            ("journal_mode=WAL", "journal_mode"),
            ("busy_timeout=5000", "busy_timeout"),
            ("synchronous=NORMAL", "synchronous")
        ]
        for (pragma, name) in pragmas {
            var errorMessage: UnsafeMutablePointer<CChar>?
            if sqlite3_exec(db, "PRAGMA \(pragma);", nil, nil, &errorMessage) != SQLITE_OK {
                let detail = errorMessage.map { String(cString: $0) } ?? "unknown"
                AppLogger.stats.error("PRAGMA failed", ["pragma": name, "detail": detail])
                sqlite3_free(errorMessage)
            }
        }
    }

    /// Verify database integrity using PRAGMA quick_check.
    /// Returns true if the database is healthy.
    private func verifyDatabaseIntegrity() -> Bool {
        guard let db = db else { return false }
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, "PRAGMA quick_check;", -1, &stmt, nil) == SQLITE_OK else {
            return false
        }
        defer { sqlite3_finalize(stmt) }
        if sqlite3_step(stmt) == SQLITE_ROW {
            if let text = sqlite3_column_text(stmt, 0) {
                return String(cString: text) == "ok"
            }
        }
        return false
    }

    /// Execute multiple writes atomically — if the app crashes mid-block, all changes are rolled back.
    func transaction(_ block: () throws -> Void) rethrows {
        // Security: check sqlite3_exec return values so transaction failures don't silently
        // leave the database in an inconsistent state (missing BEGIN/COMMIT/ROLLBACK).
        if sqlite3_exec(db, "BEGIN EXCLUSIVE", nil, nil, nil) != SQLITE_OK {
            AppLogger.stats.error("Transaction BEGIN EXCLUSIVE failed", ["sqlite_error": dbErrorMessage()])
        }
        do {
            try block()
            if sqlite3_exec(db, "COMMIT", nil, nil, nil) != SQLITE_OK {
                AppLogger.stats.error("Transaction COMMIT failed", ["sqlite_error": dbErrorMessage()])
            }
        } catch {
            if sqlite3_exec(db, "ROLLBACK", nil, nil, nil) != SQLITE_OK {
                AppLogger.stats.error("Transaction ROLLBACK failed", ["sqlite_error": dbErrorMessage()])
            }
            throw error
        }
    }

    /// Log and return the sqlite3_errmsg for the current database connection
    func dbErrorMessage() -> String {
        if let db = db {
            return String(cString: sqlite3_errmsg(db))
        }
        return "database not open"
    }

    private func createTables() {
        let createRecordingsTable = """
        CREATE TABLE IF NOT EXISTS recordings (
            id TEXT PRIMARY KEY,
            date TEXT NOT NULL,
            time TEXT NOT NULL,
            duration_seconds INTEGER NOT NULL DEFAULT 0,
            word_count INTEGER NOT NULL DEFAULT 0,
            speaker_count INTEGER NOT NULL DEFAULT 0,
            processing_time_ms INTEGER NOT NULL DEFAULT 0,
            transcript_path TEXT,
            title TEXT,
            created_at TEXT DEFAULT CURRENT_TIMESTAMP
        );
        """

        let createDailyActivityTable = """
        CREATE TABLE IF NOT EXISTS daily_activity (
            date TEXT PRIMARY KEY,
            recording_count INTEGER NOT NULL DEFAULT 0,
            total_duration_seconds INTEGER NOT NULL DEFAULT 0,
            action_items_count INTEGER NOT NULL DEFAULT 0,
            updated_at TEXT DEFAULT CURRENT_TIMESTAMP
        );
        """

        // Create indexes for common queries
        let createDateIndex = "CREATE INDEX IF NOT EXISTS idx_recordings_date ON recordings(date);"
        let createDateTimeIndex = "CREATE INDEX IF NOT EXISTS idx_recordings_date_time ON recordings(date DESC, time DESC);"
        executeSQL(createRecordingsTable)
        executeSQL(createDailyActivityTable)
        executeSQL(createDateIndex)
        executeSQL(createDateTimeIndex)
        FileManager.default.restrictSQLiteArtifactsToOwnerOnly(atPath: dbPath.path)
    }

    func executeSQL(_ sql: String) {
        var errorMessage: UnsafeMutablePointer<CChar>?
        if sqlite3_exec(db, sql, nil, nil, &errorMessage) != SQLITE_OK {
            if let error = errorMessage {
                AppLogger.stats.error("SQL error", ["message": String(cString: error)])
                sqlite3_free(errorMessage)
            }
        }
    }

    // MARK: - Recording Operations

    /// Record a new transcription session (thread-safe, async)
    public func recordSession(_ metadata: RecordingMetadata) {
        queue.async { [weak self] in
            self?.recordSessionImpl(metadata)
        }
    }

    private func recordSessionImpl(_ metadata: RecordingMetadata) {
        guard isDatabaseOpen else {
            AppLogger.stats.error("recordSession skipped — database not open")
            return
        }

        // Wrap INSERT + daily activity update in a transaction so both succeed or neither does
        transaction {
            let sql = """
            INSERT OR REPLACE INTO recordings (id, date, time, duration_seconds, word_count, speaker_count, processing_time_ms, transcript_path, title, created_at)
            VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?);
            """

            var statement: OpaquePointer?

            if sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK {
                let dateFormatter = DateFormatter()
                dateFormatter.locale = Locale(identifier: "en_US_POSIX")
                dateFormatter.dateFormat = "yyyy-MM-dd"
                let dateString = dateFormatter.string(from: metadata.date)

                let timeFormatter = DateFormatter()
                timeFormatter.locale = Locale(identifier: "en_US_POSIX")
                timeFormatter.dateFormat = "HH:mm:ss"
                let timeString = timeFormatter.string(from: metadata.date)

                let isoFormatter = ISO8601DateFormatter()
                let createdAt = isoFormatter.string(from: metadata.date)

                sqlite3_bind_text(statement, 1, (metadata.id as NSString).utf8String, -1, SQLITE_TRANSIENT)
                sqlite3_bind_text(statement, 2, (dateString as NSString).utf8String, -1, SQLITE_TRANSIENT)
                sqlite3_bind_text(statement, 3, (timeString as NSString).utf8String, -1, SQLITE_TRANSIENT)
                sqlite3_bind_int(statement, 4, Int32(metadata.durationSeconds))
                sqlite3_bind_int(statement, 5, Int32(metadata.wordCount))
                sqlite3_bind_int(statement, 6, Int32(metadata.speakerCount))
                sqlite3_bind_int(statement, 7, Int32(metadata.processingTimeMs))
                sqlite3_bind_text(statement, 8, ((metadata.transcriptPath ?? "") as NSString).utf8String, -1, SQLITE_TRANSIENT)
                sqlite3_bind_text(statement, 9, ((metadata.title ?? "") as NSString).utf8String, -1, SQLITE_TRANSIENT)
                sqlite3_bind_text(statement, 10, (createdAt as NSString).utf8String, -1, SQLITE_TRANSIENT)

                if sqlite3_step(statement) != SQLITE_DONE {
                    AppLogger.stats.error("Failed to insert recording", ["sqlite_error": dbErrorMessage()])
                }
            } else {
                AppLogger.stats.error("Failed to prepare recordSession insert", ["sqlite_error": dbErrorMessage()])
            }

            sqlite3_finalize(statement)

            // Update daily activity (inside same transaction)
            updateDailyActivityImpl(for: metadata.date, durationDelta: metadata.durationSeconds)
        }
    }

    /// Get all recordings (thread-safe, sync)
    public func getAllRecordings() -> [RecordingMetadata] {
        return queue.sync {
            getAllRecordingsImpl()
        }
    }

    private func getAllRecordingsImpl() -> [RecordingMetadata] {
        var recordings: [RecordingMetadata] = []

        let sql = "SELECT id, date, time, duration_seconds, word_count, speaker_count, processing_time_ms, transcript_path, title FROM recordings ORDER BY date DESC, time DESC;"
        var statement: OpaquePointer?

        if sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK {
            while sqlite3_step(statement) == SQLITE_ROW {
                if let recording = recordingMetadataFromRow(statement) {
                    recordings.append(recording)
                }
            }
        } else {
            AppLogger.stats.error("Failed to prepare getAllRecordings", ["sqlite_error": dbErrorMessage()])
        }

        sqlite3_finalize(statement)
        return recordings
    }

    /// Get the most recent recordings without materializing the full table.
    public func getRecentRecordings(limit: Int) -> [RecordingMetadata] {
        guard limit > 0 else { return [] }
        return queue.sync {
            getRecentRecordingsImpl(limit: limit)
        }
    }

    private func getRecentRecordingsImpl(limit: Int) -> [RecordingMetadata] {
        var recordings: [RecordingMetadata] = []

        let sql = """
        SELECT id, date, time, duration_seconds, word_count, speaker_count, processing_time_ms, transcript_path, title
        FROM recordings
        ORDER BY date DESC, time DESC
        LIMIT ?;
        """
        var statement: OpaquePointer?

        if sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK {
            sqlite3_bind_int(statement, 1, Int32(limit))

            while sqlite3_step(statement) == SQLITE_ROW {
                if let recording = recordingMetadataFromRow(statement) {
                    recordings.append(recording)
                }
            }
        } else {
            AppLogger.stats.error("Failed to prepare getRecentRecordings", ["sqlite_error": dbErrorMessage()])
        }

        sqlite3_finalize(statement)
        return recordings
    }

    /// Parses a RecordingMetadata from the current row of a prepared SELECT statement.
    /// Expected column order: id(0), date(1), time(2), duration_seconds(3), word_count(4),
    /// speaker_count(5), processing_time_ms(6), transcript_path(7), title(8)
    func recordingMetadataFromRow(_ statement: OpaquePointer?) -> RecordingMetadata? {
        guard let idPtr = sqlite3_column_text(statement, 0) else { return nil }
        let id = String(cString: idPtr)
        let dateStr = sqlite3_column_text(statement, 1).map(String.init(cString:)) ?? ""
        let timeStr = sqlite3_column_text(statement, 2).map(String.init(cString:)) ?? ""
        let duration = Int(sqlite3_column_int(statement, 3))
        let wordCount = Int(sqlite3_column_int(statement, 4))
        let speakerCount = Int(sqlite3_column_int(statement, 5))
        let processingTime = Int(sqlite3_column_int(statement, 6))
        let transcriptPath: String? = sqlite3_column_text(statement, 7).map { String(cString: $0) }
        let title: String? = sqlite3_column_text(statement, 8).map { String(cString: $0) }

        let date = Self.rowDateFormatter.date(from: "\(dateStr) \(timeStr)") ?? Date()

        return RecordingMetadata(
            id: id,
            date: date,
            durationSeconds: duration,
            wordCount: wordCount,
            speakerCount: speakerCount,
            processingTimeMs: processingTime,
            transcriptPath: transcriptPath,
            title: title
        )
    }

    // MARK: - Daily Activity Update

    func updateDailyActivityImpl(for date: Date, durationDelta: Int) {
        let dateFormatter = DateFormatter()
        dateFormatter.dateFormat = "yyyy-MM-dd"
        let dateStr = dateFormatter.string(from: date)

        // Upsert: insert new or increment existing daily activity
        let updateSQL = """
        INSERT INTO daily_activity (date, recording_count, total_duration_seconds, action_items_count, updated_at)
        VALUES (?, 1, ?, 0, datetime('now'))
        ON CONFLICT(date) DO UPDATE SET
            recording_count = recording_count + 1,
            total_duration_seconds = total_duration_seconds + ?,
            updated_at = datetime('now');
        """

        var statement: OpaquePointer?

        if sqlite3_prepare_v2(db, updateSQL, -1, &statement, nil) == SQLITE_OK {
            sqlite3_bind_text(statement, 1, (dateStr as NSString).utf8String, -1, SQLITE_TRANSIENT)
            sqlite3_bind_int(statement, 2, Int32(durationDelta))
            sqlite3_bind_int(statement, 3, Int32(durationDelta))

            if sqlite3_step(statement) != SQLITE_DONE {
                AppLogger.stats.error("Failed to update daily activity", ["sqlite_error": dbErrorMessage()])
            }
        } else {
            AppLogger.stats.error("Failed to prepare updateDailyActivity", ["sqlite_error": dbErrorMessage()])
        }

        sqlite3_finalize(statement)
    }
}

// MARK: - StatsStore conformance
// Empty extension — protocol signatures match StatsDatabase's existing public API.
// Added as part of Step 8 protocol wiring (merge-plan §5.1).

extension StatsDatabase: StatsStore {}
