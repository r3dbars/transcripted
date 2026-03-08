import Foundation
import SQLite3

/// SQLite database for persistent stats tracking
/// Stores recording history, action items, and daily activity for the dashboard
@available(macOS 14.0, *)
final class StatsDatabase {

    static let shared = StatsDatabase()

    private var db: OpaquePointer?
    private var isDatabaseOpen = false
    private let dbPath: URL

    /// Serial queue ensuring thread-safe database access
    /// All database operations are serialized through this queue
    private let queue = DispatchQueue(label: "com.transcripted.statsdb", qos: .utility)

    /// SQLITE_TRANSIENT tells SQLite to copy text immediately, preventing dangling pointer issues
    /// from temporary (NSString).utf8String pointers
    private let SQLITE_TRANSIENT = unsafeBitCast(-1, to: sqlite3_destructor_type.self)

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
            // WAL mode for crash safety, busy timeout to avoid SQLITE_BUSY, NORMAL sync for performance
            sqlite3_exec(db, "PRAGMA journal_mode=WAL; PRAGMA busy_timeout=5000; PRAGMA synchronous=NORMAL;", nil, nil, nil)
            AppLogger.stats.info("Opened database", ["path": dbPath.path])
        }
    }

    /// Execute multiple writes atomically — if the app crashes mid-block, all changes are rolled back.
    private func transaction(_ block: () throws -> Void) rethrows {
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
    private func dbErrorMessage() -> String {
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

    private func executeSQL(_ sql: String) {
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

    /// Get recordings for a specific date range (thread-safe, sync)
    func getRecordings(from startDate: Date, to endDate: Date) -> [RecordingMetadata] {
        return queue.sync {
            getRecordingsImpl(from: startDate, to: endDate)
        }
    }

    private func getRecordingsImpl(from startDate: Date, to endDate: Date) -> [RecordingMetadata] {
        var recordings: [RecordingMetadata] = []

        let dateFormatter = DateFormatter()
        dateFormatter.dateFormat = "yyyy-MM-dd"
        let startStr = dateFormatter.string(from: startDate)
        let endStr = dateFormatter.string(from: endDate)

        let sql = "SELECT id, date, time, duration_seconds, word_count, speaker_count, processing_time_ms, transcript_path, title FROM recordings WHERE date >= ? AND date <= ? ORDER BY date DESC, time DESC;"
        var statement: OpaquePointer?

        if sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK {
            sqlite3_bind_text(statement, 1, (startStr as NSString).utf8String, -1, SQLITE_TRANSIENT)
            sqlite3_bind_text(statement, 2, (endStr as NSString).utf8String, -1, SQLITE_TRANSIENT)

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

                let dateTimeFormatter = DateFormatter()
                dateTimeFormatter.dateFormat = "yyyy-MM-dd HH:mm:ss"
                let date = dateTimeFormatter.date(from: "\(dateStr) \(timeStr)") ?? Date()

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
            AppLogger.stats.error("Failed to prepare getRecordings", ["sqlite_error": dbErrorMessage()])
        }

        sqlite3_finalize(statement)
        return recordings
    }

    // MARK: - Daily Activity Operations

    private func updateDailyActivityImpl(for date: Date, durationDelta: Int) {
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

    /// Get daily activity for a month (thread-safe, sync)
    func getDailyActivity(for month: Date) -> [String: DailyActivity] {
        return queue.sync {
            getDailyActivityImpl(for: month)
        }
    }

    private func getDailyActivityImpl(for month: Date) -> [String: DailyActivity] {
        var activities: [String: DailyActivity] = [:]

        // Get first and last day of month
        let calendar = Calendar.current
        guard let startOfMonth = calendar.date(from: calendar.dateComponents([.year, .month], from: month)),
              let endOfMonth = calendar.date(byAdding: DateComponents(month: 1, day: -1), to: startOfMonth) else {
            return activities
        }

        let dateFormatter = DateFormatter()
        dateFormatter.dateFormat = "yyyy-MM-dd"
        let startStr = dateFormatter.string(from: startOfMonth)
        let endStr = dateFormatter.string(from: endOfMonth)

        let sql = "SELECT date, recording_count, total_duration_seconds, action_items_count FROM daily_activity WHERE date >= ? AND date <= ?;"
        var statement: OpaquePointer?

        if sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK {
            sqlite3_bind_text(statement, 1, (startStr as NSString).utf8String, -1, SQLITE_TRANSIENT)
            sqlite3_bind_text(statement, 2, (endStr as NSString).utf8String, -1, SQLITE_TRANSIENT)

            while sqlite3_step(statement) == SQLITE_ROW {
                let dateStr = String(cString: sqlite3_column_text(statement, 0))
                let recordingCount = Int(sqlite3_column_int(statement, 1))
                let totalDuration = Int(sqlite3_column_int(statement, 2))
                let actionItems = Int(sqlite3_column_int(statement, 3))

                activities[dateStr] = DailyActivity(
                    date: dateStr,
                    recordingCount: recordingCount,
                    totalDurationSeconds: totalDuration,
                    actionItemsCount: actionItems
                )
            }
        } else {
            AppLogger.stats.error("Failed to prepare getDailyActivity", ["sqlite_error": dbErrorMessage()])
        }

        sqlite3_finalize(statement)
        return activities
    }

    /// Get all dates with activity (for streak calculation) (thread-safe, sync)
    func getAllActiveDates() -> [String] {
        return queue.sync {
            getAllActiveDatesImpl()
        }
    }

    private func getAllActiveDatesImpl() -> [String] {
        var dates: [String] = []

        let sql = "SELECT date FROM daily_activity WHERE recording_count > 0 ORDER BY date DESC;"
        var statement: OpaquePointer?

        if sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK {
            while sqlite3_step(statement) == SQLITE_ROW {
                let dateStr = String(cString: sqlite3_column_text(statement, 0))
                dates.append(dateStr)
            }
        } else {
            AppLogger.stats.error("Failed to prepare getAllActiveDates", ["sqlite_error": dbErrorMessage()])
        }

        sqlite3_finalize(statement)
        return dates
    }

    // MARK: - Aggregate Stats

    /// Get total recordings count (thread-safe, sync)
    func getTotalRecordingsCount() -> Int {
        return queue.sync {
            getTotalRecordingsCountImpl()
        }
    }

    private func getTotalRecordingsCountImpl() -> Int {
        let sql = "SELECT COUNT(*) FROM recordings;"
        var statement: OpaquePointer?
        var count = 0

        if sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK {
            if sqlite3_step(statement) == SQLITE_ROW {
                count = Int(sqlite3_column_int(statement, 0))
            }
        } else {
            AppLogger.stats.error("Failed to prepare getTotalRecordingsCount", ["sqlite_error": dbErrorMessage()])
        }

        sqlite3_finalize(statement)
        return count
    }

    /// Get total duration in seconds (thread-safe, sync)
    func getTotalDurationSeconds() -> Int {
        return queue.sync {
            getTotalDurationSecondsImpl()
        }
    }

    private func getTotalDurationSecondsImpl() -> Int {
        let sql = "SELECT COALESCE(SUM(duration_seconds), 0) FROM recordings;"
        var statement: OpaquePointer?
        var total = 0

        if sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK {
            if sqlite3_step(statement) == SQLITE_ROW {
                total = Int(sqlite3_column_int(statement, 0))
            }
        } else {
            AppLogger.stats.error("Failed to prepare getTotalDurationSeconds", ["sqlite_error": dbErrorMessage()])
        }

        sqlite3_finalize(statement)
        return total
    }

    /// Get stats for the last N days (thread-safe, sync)
    func getStatsForLastDays(_ days: Int) -> (recordings: Int, durationSeconds: Int) {
        return queue.sync {
            getStatsForLastDaysImpl(days)
        }
    }

    private func getStatsForLastDaysImpl(_ days: Int) -> (recordings: Int, durationSeconds: Int) {
        let dateFormatter = DateFormatter()
        dateFormatter.dateFormat = "yyyy-MM-dd"
        let startDate = Calendar.current.date(byAdding: .day, value: -days, to: Date()) ?? Date()
        let startStr = dateFormatter.string(from: startDate)

        var recordings = 0
        var duration = 0

        let recordingSQL = "SELECT COUNT(*), COALESCE(SUM(duration_seconds), 0) FROM recordings WHERE date >= ?;"
        var statement: OpaquePointer?

        if sqlite3_prepare_v2(db, recordingSQL, -1, &statement, nil) == SQLITE_OK {
            sqlite3_bind_text(statement, 1, (startStr as NSString).utf8String, -1, SQLITE_TRANSIENT)

            if sqlite3_step(statement) == SQLITE_ROW {
                recordings = Int(sqlite3_column_int(statement, 0))
                duration = Int(sqlite3_column_int(statement, 1))
            }
        } else {
            AppLogger.stats.error("Failed to prepare getStatsForLastDays", ["sqlite_error": dbErrorMessage()])
        }
        sqlite3_finalize(statement)

        return (recordings, duration)
    }

    // MARK: - Migration Support

    /// Check if a recording exists by transcript path (thread-safe, sync)
    func recordingExists(transcriptPath: String) -> Bool {
        return queue.sync {
            recordingExistsImpl(transcriptPath: transcriptPath)
        }
    }

    private func recordingExistsImpl(transcriptPath: String) -> Bool {
        let sql = "SELECT COUNT(*) FROM recordings WHERE transcript_path = ?;"
        var statement: OpaquePointer?
        var exists = false

        if sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK {
            sqlite3_bind_text(statement, 1, (transcriptPath as NSString).utf8String, -1, SQLITE_TRANSIENT)

            if sqlite3_step(statement) == SQLITE_ROW {
                exists = sqlite3_column_int(statement, 0) > 0
            }
        } else {
            AppLogger.stats.error("Failed to prepare recordingExists", ["sqlite_error": dbErrorMessage()])
        }

        sqlite3_finalize(statement)
        return exists
    }

    /// Clear all data (for testing) (thread-safe, async)
    func clearAllData() {
        queue.async { [weak self] in
            self?.clearAllDataImpl()
        }
    }

    private func clearAllDataImpl() {
        executeSQL("DELETE FROM recordings;")
        executeSQL("DELETE FROM daily_activity;")
        AppLogger.stats.info("Cleared all data")
    }
}

// MARK: - Data Models

/// Metadata for a recording session
struct RecordingMetadata: Identifiable {
    let id: String
    let date: Date
    let durationSeconds: Int
    let wordCount: Int
    let speakerCount: Int
    let processingTimeMs: Int
    let transcriptPath: String?
    let title: String?

    init(
        id: String = UUID().uuidString,
        date: Date,
        durationSeconds: Int,
        wordCount: Int = 0,
        speakerCount: Int = 0,
        processingTimeMs: Int = 0,
        transcriptPath: String? = nil,
        title: String? = nil
    ) {
        self.id = id
        self.date = date
        self.durationSeconds = durationSeconds
        self.wordCount = wordCount
        self.speakerCount = speakerCount
        self.processingTimeMs = processingTimeMs
        self.transcriptPath = transcriptPath
        self.title = title
    }

    /// Format duration as "Xh Ym" or "Xm"
    var formattedDuration: String {
        let hours = durationSeconds / 3600
        let minutes = (durationSeconds % 3600) / 60

        if hours > 0 {
            return "\(hours)h \(minutes)m"
        } else {
            return "\(minutes)m"
        }
    }

    /// Display title (fallback to date if no title)
    var displayTitle: String {
        if let title = title, !title.isEmpty {
            return title
        }
        let formatter = DateFormatter()
        formatter.dateStyle = .medium
        formatter.timeStyle = .short
        return "Recording - \(formatter.string(from: date))"
    }
}

/// Daily activity summary
struct DailyActivity {
    let date: String // "yyyy-MM-dd"
    let recordingCount: Int
    let totalDurationSeconds: Int
    let actionItemsCount: Int

    /// Intensity level (0-4) for heat map
    var intensityLevel: Int {
        if recordingCount == 0 {
            return 0
        } else if recordingCount == 1 {
            return 1
        } else if recordingCount <= 3 {
            return 2
        } else if recordingCount <= 5 {
            return 3
        } else {
            return 4
        }
    }

    /// Format total duration for display
    var formattedDuration: String {
        let hours = totalDurationSeconds / 3600
        let minutes = (totalDurationSeconds % 3600) / 60

        if hours > 0 {
            return "\(hours)h \(minutes)m"
        } else {
            return "\(minutes)m"
        }
    }
}
