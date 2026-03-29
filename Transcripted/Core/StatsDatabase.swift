import Foundation
import SQLite3

/// SQLite database for persistent stats tracking
/// Stores recording history, action items, and daily activity for the dashboard
@available(macOS 14.0, *)
final class StatsDatabase {

    static let shared = StatsDatabase()

    var db: OpaquePointer?
    var isDatabaseOpen = false
    let dbPath: URL

    /// Serial queue ensuring thread-safe database access
    /// All database operations are serialized through this queue
    let queue = DispatchQueue(label: "com.transcripted.statsdb", qos: .utility)

    /// SQLITE_TRANSIENT tells SQLite to copy text immediately, preventing dangling pointer issues
    /// from temporary (NSString).utf8String pointers
    let SQLITE_TRANSIENT = unsafeBitCast(-1, to: sqlite3_destructor_type.self)

    private init() {
        // Store database in the Transcripted folder
        let documentsPath = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        let transcriptedFolder = documentsPath.appendingPathComponent("Transcripted")

        // Create folder if needed
        try? FileManager.default.createDirectory(at: transcriptedFolder, withIntermediateDirectories: true)

        dbPath = transcriptedFolder.appendingPathComponent("stats.sqlite")

        openDatabase()
        createTables()
    }

    deinit {
        sqlite3_close(db)
    }

    // MARK: - Database Setup

    private func openDatabase() {
        if sqlite3_open(dbPath.path, &db) != SQLITE_OK {
            AppLogger.stats.error("Failed to open database", ["path": dbPath.path])
            isDatabaseOpen = false
        } else {
            isDatabaseOpen = true
            FileManager.default.restrictToOwnerOnly(atPath: dbPath.path)
            // WAL mode for crash safety, busy timeout to avoid SQLITE_BUSY, NORMAL sync for performance
            sqlite3_exec(db, "PRAGMA journal_mode=WAL; PRAGMA busy_timeout=5000; PRAGMA synchronous=NORMAL;", nil, nil, nil)
            AppLogger.stats.info("Opened database", ["path": dbPath.path])
        }
    }

    /// Execute multiple writes atomically — if the app crashes mid-block, all changes are rolled back.
    func transaction(_ block: () throws -> Void) rethrows {
        sqlite3_exec(db, "BEGIN EXCLUSIVE", nil, nil, nil)
        do {
            try block()
            sqlite3_exec(db, "COMMIT", nil, nil, nil)
        } catch {
            sqlite3_exec(db, "ROLLBACK", nil, nil, nil)
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
        executeSQL(createRecordingsTable)
        executeSQL(createDailyActivityTable)
        executeSQL(createDateIndex)
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
    func recordSession(_ metadata: RecordingMetadata) {
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
    func getAllRecordings() -> [RecordingMetadata] {
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
                let id = String(cString: sqlite3_column_text(statement, 0))
                let dateStr = String(cString: sqlite3_column_text(statement, 1))
                let timeStr = String(cString: sqlite3_column_text(statement, 2))
                let duration = Int(sqlite3_column_int(statement, 3))
                let wordCount = Int(sqlite3_column_int(statement, 4))
                let speakerCount = Int(sqlite3_column_int(statement, 5))
                let processingTime = Int(sqlite3_column_int(statement, 6))

                let transcriptPath: String? = sqlite3_column_text(statement, 7).map { String(cString: $0) }
                let title: String? = sqlite3_column_text(statement, 8).map { String(cString: $0) }

                // Parse date and time
                let dateFormatter = DateFormatter()
                dateFormatter.dateFormat = "yyyy-MM-dd HH:mm:ss"
                let date = dateFormatter.date(from: "\(dateStr) \(timeStr)") ?? Date()

                let recording = RecordingMetadata(
                    id: id,
                    date: date,
                    durationSeconds: duration,
                    wordCount: wordCount,
                    speakerCount: speakerCount,
                    processingTimeMs: processingTime,
                    transcriptPath: transcriptPath,
                    title: title
                )
                recordings.append(recording)
            }
        } else {
            AppLogger.stats.error("Failed to prepare getAllRecordings", ["sqlite_error": dbErrorMessage()])
        }

        sqlite3_finalize(statement)
        return recordings
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
