import Foundation
import SQLite3

// MARK: - Complex Queries & Aggregations

@available(macOS 14.0, *)
extension StatsDatabase {

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
