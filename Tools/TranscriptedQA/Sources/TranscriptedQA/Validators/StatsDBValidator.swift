import Foundation

struct StatsDBValidator {
    let dbPath: String

    func validate() -> [ValidationResult] {
        var results: [ValidationResult] = []
        let target = "stats.sqlite"

        guard FileManager.default.fileExists(atPath: dbPath) else {
            return [.warn("database/stats-exists", target: target, detail: "stats.sqlite not found")]
        }

        guard let db = try? SQLiteReader(path: dbPath) else {
            return [.fail("database/stats-open", target: target, detail: "Cannot open stats.sqlite")]
        }

        // Integrity
        if let result = try? db.pragma("integrity_check"), result == "ok" {
            results.append(.pass("database/stats-integrity", target: target))
        } else {
            results.append(.fail("database/stats-integrity", target: target, detail: "PRAGMA integrity_check failed"))
        }

        // Schema — recordings table
        if let columns = try? db.tableColumns("recordings") {
            let expected = ["id", "date", "time", "duration_seconds", "word_count",
                           "speaker_count", "processing_time_ms", "transcript_path", "title", "created_at"]
            let actual = columns.map { $0.name }
            let missing = expected.filter { !actual.contains($0) }
            if missing.isEmpty {
                results.append(.pass("database/stats-schema-recordings", target: target))
            } else {
                results.append(.fail("database/stats-schema-recordings", target: target, detail: "Missing columns: \(missing.joined(separator: ", "))"))
            }
        }

        // Schema — daily_activity table
        if let columns = try? db.tableColumns("daily_activity") {
            let expected = ["date", "recording_count", "total_duration_seconds", "action_items_count"]
            let actual = columns.map { $0.name }
            let missing = expected.filter { !actual.contains($0) }
            if missing.isEmpty {
                results.append(.pass("database/stats-schema-daily", target: target))
            } else {
                results.append(.fail("database/stats-schema-daily", target: target, detail: "Missing columns: \(missing.joined(separator: ", "))"))
            }
        }

        // Positive durations
        if let rows = try? db.query("SELECT id, duration_seconds FROM recordings WHERE duration_seconds < 0") {
            if rows.isEmpty {
                results.append(.pass("database/stats-positive-durations", target: target))
            } else {
                results.append(.fail("database/stats-positive-durations", target: target, detail: "\(rows.count) recordings with negative duration"))
            }
        }

        // Valid dates (basic check: matches yyyy-MM-dd pattern)
        if let rows = try? db.query("SELECT date FROM recordings") {
            let dateRegex = try! NSRegularExpression(pattern: "^\\d{4}-\\d{2}-\\d{2}$")
            let invalidDates = rows.compactMap { row -> String? in
                guard let date = row["date"] as? String else { return "NULL" }
                let range = NSRange(date.startIndex..., in: date)
                return dateRegex.firstMatch(in: date, range: range) == nil ? date : nil
            }
            if invalidDates.isEmpty {
                results.append(.pass("database/stats-valid-dates", target: target))
            } else {
                results.append(.fail("database/stats-valid-dates", target: target, detail: "Invalid dates: \(invalidDates.prefix(3).joined(separator: ", "))"))
            }
        }

        // File permissions
        if let attrs = try? FileManager.default.attributesOfItem(atPath: dbPath),
           let perms = attrs[.posixPermissions] as? Int {
            if perms & 0o077 == 0 {
                results.append(.pass("database/stats-permissions", target: target))
            } else {
                results.append(.warn("database/stats-permissions", target: target, detail: "Permissions \(String(perms, radix: 8)) — expected 0600"))
            }
        }

        return results
    }
}
