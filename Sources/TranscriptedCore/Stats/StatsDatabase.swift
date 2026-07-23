import Foundation
import SQLite3

/// SQLite database for persistent stats tracking
/// Stores recording history, action items, and daily activity for the dashboard
@available(macOS 14.0, *)
public final class StatsDatabase {

    private enum DatabaseWriteError: Error, CustomStringConvertible {
        case sqlite(operation: String, message: String)

        var description: String {
            switch self {
            case let .sqlite(operation, message):
                return "SQLite \(operation) failed: \(message)"
            }
        }
    }

    public static let shared = StatsDatabase()

    var db: OpaquePointer?
    // Thread-safety invariant: writes happen only during `init`
    // (single-threaded construction); reads happen only inside `queue.sync`.
    // See the matching comment in `SpeakerDatabase` for the rationale.
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
        openDatabase()
        createTables()
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
        openDatabase()
        createTables()
    }

    deinit {
        sqlite3_close(db)
    }

    // MARK: - Database Setup

    private func openDatabase() {
        // Security: check each PRAGMA return value so a silent failure (e.g. WAL mode refused
        // because another process holds the db) is logged rather than silently misconfiguring
        // the database. Matches the same pattern used in SpeakerDatabase.openDatabase().
        db = SQLiteHandle.open(
            at: dbPath,
            onOpenFailure: { sqliteError in
                AppLogger.stats.error("Failed to open stats database", ["path": dbPath.path, "sqlite_error": sqliteError])
            },
            onPragmaFailure: { name, detail in
                AppLogger.stats.error("PRAGMA failed", ["pragma": name, "detail": detail])
            }
        )
        guard db != nil else {
            isDatabaseOpen = false
            return
        }
        // Security: mark the database open only after all pragmas are applied so any concurrent
        // reader that observes isDatabaseOpen=true is guaranteed to see a fully-configured handle.
        isDatabaseOpen = true

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
            db = SQLiteHandle.open(
                at: dbPath,
                onPragmaFailure: { name, detail in
                    AppLogger.stats.error("PRAGMA failed", ["pragma": name, "detail": detail])
                }
            )
            if db != nil {
                isDatabaseOpen = true
                AppLogger.stats.info("Recreated fresh database after corruption recovery")
            } else {
                isDatabaseOpen = false
                AppLogger.stats.error("Failed to recreate database after corruption recovery")
            }
        } else {
            AppLogger.stats.info("Opened database", ["path": dbPath.path])
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
    func transaction(_ block: () throws -> Void) throws {
        guard sqlite3_exec(db, "BEGIN EXCLUSIVE", nil, nil, nil) == SQLITE_OK else {
            let message = dbErrorMessage()
            AppLogger.stats.error("Transaction BEGIN EXCLUSIVE failed", ["sqlite_error": message])
            throw DatabaseWriteError.sqlite(operation: "BEGIN EXCLUSIVE", message: message)
        }

        do {
            try block()
            guard sqlite3_exec(db, "COMMIT", nil, nil, nil) == SQLITE_OK else {
                let message = dbErrorMessage()
                AppLogger.stats.error("Transaction COMMIT failed", ["sqlite_error": message])
                throw DatabaseWriteError.sqlite(operation: "COMMIT", message: message)
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
        let createTranscriptPathIndex = "CREATE INDEX IF NOT EXISTS idx_recordings_transcript_path ON recordings(transcript_path);"
        executeSQL(createRecordingsTable)
        executeSQL(createDailyActivityTable)
        executeSQL(createDateIndex)
        executeSQL(createDateTimeIndex)
        executeSQL(createTranscriptPathIndex)
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

        // Wrap INSERT + daily activity update in a transaction so both succeed or neither does.
        do {
            try transaction {
                let existing = try recordingMetadataImpl(id: metadata.id)
                    ?? recordingMetadataImpl(transcriptPath: metadata.transcriptPath)
                let storedMetadata = RecordingMetadata(
                    id: existing?.id ?? metadata.id,
                    date: metadata.date,
                    durationSeconds: metadata.durationSeconds,
                    wordCount: metadata.wordCount,
                    speakerCount: metadata.speakerCount,
                    processingTimeMs: metadata.processingTimeMs,
                    transcriptPath: metadata.transcriptPath,
                    title: metadata.title
                )
                let sql = """
                INSERT OR REPLACE INTO recordings (id, date, time, duration_seconds, word_count, speaker_count, processing_time_ms, transcript_path, title, created_at)
                VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?);
                """

                var statement: OpaquePointer?
                guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK,
                      let statement else {
                    throw DatabaseWriteError.sqlite(
                        operation: "prepare recordSession insert",
                        message: dbErrorMessage()
                    )
                }
                defer { sqlite3_finalize(statement) }

                let dateFormatter = DateFormatter()
                dateFormatter.locale = Locale(identifier: "en_US_POSIX")
                dateFormatter.dateFormat = "yyyy-MM-dd"
                let dateString = dateFormatter.string(from: storedMetadata.date)

                let timeFormatter = DateFormatter()
                timeFormatter.locale = Locale(identifier: "en_US_POSIX")
                timeFormatter.dateFormat = "HH:mm:ss"
                let timeString = timeFormatter.string(from: storedMetadata.date)

                let isoFormatter = ISO8601DateFormatter()
                let createdAt = isoFormatter.string(from: storedMetadata.date)

                sqlite3_bind_text(statement, 1, (storedMetadata.id as NSString).utf8String, -1, SQLITE_TRANSIENT)
                sqlite3_bind_text(statement, 2, (dateString as NSString).utf8String, -1, SQLITE_TRANSIENT)
                sqlite3_bind_text(statement, 3, (timeString as NSString).utf8String, -1, SQLITE_TRANSIENT)
                sqlite3_bind_int(statement, 4, Int32(storedMetadata.durationSeconds))
                sqlite3_bind_int(statement, 5, Int32(storedMetadata.wordCount))
                sqlite3_bind_int(statement, 6, Int32(storedMetadata.speakerCount))
                sqlite3_bind_int(statement, 7, Int32(storedMetadata.processingTimeMs))
                sqlite3_bind_text(statement, 8, ((storedMetadata.transcriptPath ?? "") as NSString).utf8String, -1, SQLITE_TRANSIENT)
                sqlite3_bind_text(statement, 9, ((storedMetadata.title ?? "") as NSString).utf8String, -1, SQLITE_TRANSIENT)
                sqlite3_bind_text(statement, 10, (createdAt as NSString).utf8String, -1, SQLITE_TRANSIENT)

                guard sqlite3_step(statement) == SQLITE_DONE else {
                    throw DatabaseWriteError.sqlite(
                        operation: "insert recording",
                        message: dbErrorMessage()
                    )
                }

                // Update daily activity (inside same transaction)
                try updateDailyActivityForSessionChange(from: existing, to: storedMetadata)
            }
        } catch {
            AppLogger.stats.error("recordSession transaction failed", ["error": String(describing: error)])
        }
    }

    private func recordingMetadataImpl(id: String) throws -> RecordingMetadata? {
        let sql = """
        SELECT id, date, time, duration_seconds, word_count, speaker_count, processing_time_ms, transcript_path, title
        FROM recordings
        WHERE id = ?
        LIMIT 1;
        """
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK else {
            throw DatabaseWriteError.sqlite(
                operation: "prepare recording lookup",
                message: dbErrorMessage()
            )
        }
        defer { sqlite3_finalize(statement) }

        sqlite3_bind_text(statement, 1, (id as NSString).utf8String, -1, SQLITE_TRANSIENT)
        switch sqlite3_step(statement) {
        case SQLITE_ROW:
            return recordingMetadataFromRow(statement)
        case SQLITE_DONE:
            return nil
        default:
            throw DatabaseWriteError.sqlite(
                operation: "step recording lookup",
                message: dbErrorMessage()
            )
        }
    }

    private func recordingMetadataImpl(transcriptPath: String?) throws -> RecordingMetadata? {
        guard let transcriptPath, !transcriptPath.isEmpty else {
            return nil
        }

        let sql = """
        SELECT id, date, time, duration_seconds, word_count, speaker_count, processing_time_ms, transcript_path, title
        FROM recordings
        WHERE transcript_path = ?
        LIMIT 1;
        """
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK else {
            throw DatabaseWriteError.sqlite(
                operation: "prepare recording path lookup",
                message: dbErrorMessage()
            )
        }
        defer { sqlite3_finalize(statement) }

        sqlite3_bind_text(statement, 1, (transcriptPath as NSString).utf8String, -1, SQLITE_TRANSIENT)
        switch sqlite3_step(statement) {
        case SQLITE_ROW:
            return recordingMetadataFromRow(statement)
        case SQLITE_DONE:
            return nil
        default:
            throw DatabaseWriteError.sqlite(
                operation: "step recording path lookup",
                message: dbErrorMessage()
            )
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

    private func updateDailyActivityForSessionChange(
        from existing: RecordingMetadata?,
        to metadata: RecordingMetadata
    ) throws {
        guard let existing else {
            try updateDailyActivityImpl(
                for: metadata.date,
                recordingCountDelta: 1,
                durationDelta: metadata.durationSeconds
            )
            return
        }

        if dailyActivityDateString(for: existing.date) == dailyActivityDateString(for: metadata.date) {
            try updateDailyActivityImpl(
                for: metadata.date,
                recordingCountDelta: 0,
                durationDelta: metadata.durationSeconds - existing.durationSeconds
            )
        } else {
            try updateDailyActivityImpl(
                for: existing.date,
                recordingCountDelta: -1,
                durationDelta: -existing.durationSeconds
            )
            try updateDailyActivityImpl(
                for: metadata.date,
                recordingCountDelta: 1,
                durationDelta: metadata.durationSeconds
            )
        }
    }

    func updateDailyActivityImpl(for date: Date, recordingCountDelta: Int, durationDelta: Int) throws {
        guard recordingCountDelta != 0 || durationDelta != 0 else { return }

        let dateFormatter = DateFormatter()
        dateFormatter.dateFormat = "yyyy-MM-dd"
        let dateStr = dateFormatter.string(from: date)

        // Upsert: insert new or increment existing daily activity
        let updateSQL = """
        INSERT INTO daily_activity (date, recording_count, total_duration_seconds, action_items_count, updated_at)
        VALUES (?, MAX(?, 0), MAX(?, 0), 0, datetime('now'))
        ON CONFLICT(date) DO UPDATE SET
            recording_count = MAX(recording_count + ?, 0),
            total_duration_seconds = MAX(total_duration_seconds + ?, 0),
            updated_at = datetime('now');
        """

        var statement: OpaquePointer?

        guard sqlite3_prepare_v2(db, updateSQL, -1, &statement, nil) == SQLITE_OK,
              let statement else {
            throw DatabaseWriteError.sqlite(
                operation: "prepare daily activity update",
                message: dbErrorMessage()
            )
        }
        defer { sqlite3_finalize(statement) }

        sqlite3_bind_text(statement, 1, (dateStr as NSString).utf8String, -1, SQLITE_TRANSIENT)
        sqlite3_bind_int(statement, 2, Int32(recordingCountDelta))
        sqlite3_bind_int(statement, 3, Int32(durationDelta))
        sqlite3_bind_int(statement, 4, Int32(recordingCountDelta))
        sqlite3_bind_int(statement, 5, Int32(durationDelta))

        guard sqlite3_step(statement) == SQLITE_DONE else {
            throw DatabaseWriteError.sqlite(
                operation: "update daily activity",
                message: dbErrorMessage()
            )
        }
    }

    private func dailyActivityDateString(for date: Date) -> String {
        let dateFormatter = DateFormatter()
        dateFormatter.dateFormat = "yyyy-MM-dd"
        return dateFormatter.string(from: date)
    }
}

// MARK: - StatsStore conformance
// Empty extension — protocol signatures match StatsDatabase's existing public API.
// Added as part of Step 8 protocol wiring (merge-plan §5.1).

extension StatsDatabase: StatsStore {}
