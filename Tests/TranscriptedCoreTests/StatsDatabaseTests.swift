import XCTest
import SQLite3
@testable import TranscriptedCore

@available(macOS 14.0, *)
final class StatsDatabaseTests: XCTestCase {

    func testGetRecentRecordingsHonorsLimitAndSortOrder() {
        let databaseURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("TranscriptedCoreStatsTests-\(UUID().uuidString).sqlite")

        let calendar = Calendar(identifier: .gregorian)
        let rows = [
            RecordingMetadata(id: "oldest", date: calendar.date(from: DateComponents(year: 2026, month: 4, day: 5, hour: 9, minute: 0))!, durationSeconds: 60),
            RecordingMetadata(id: "middle", date: calendar.date(from: DateComponents(year: 2026, month: 4, day: 6, hour: 10, minute: 30))!, durationSeconds: 120),
            RecordingMetadata(id: "newer", date: calendar.date(from: DateComponents(year: 2026, month: 4, day: 7, hour: 8, minute: 15))!, durationSeconds: 180),
            RecordingMetadata(id: "newest", date: calendar.date(from: DateComponents(year: 2026, month: 4, day: 7, hour: 18, minute: 45))!, durationSeconds: 240),
        ]

        do {
            let database = StatsDatabase(path: databaseURL.path)

            for row in rows {
                database.recordSession(row)
            }
            database.queue.sync {}

            XCTAssertEqual(database.getRecentRecordings(limit: 2).map(\.id), ["newest", "newer"])
            XCTAssertEqual(database.getRecentRecordings(limit: 10).map(\.id), ["newest", "newer", "middle", "oldest"])
            XCTAssertTrue(database.getRecentRecordings(limit: 0).isEmpty)
        }

        for suffix in ["", "-shm", "-wal"] {
            try? FileManager.default.removeItem(at: URL(fileURLWithPath: databaseURL.path + suffix))
        }
    }

    func testReplacingRecordingUpdatesDailyActivityInsteadOfDoubleCounting() {
        let databaseURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("TranscriptedCoreStatsTests-\(UUID().uuidString).sqlite")
        let date = Calendar(identifier: .gregorian).date(
            from: DateComponents(year: 2026, month: 4, day: 5, hour: 9, minute: 0)
        )!

        do {
            let database = StatsDatabase(path: databaseURL.path)
            database.recordSession(RecordingMetadata(
                id: "same-transcript",
                date: date,
                durationSeconds: 60,
                transcriptPath: "/synthetic/meeting.md"
            ))
            database.recordSession(RecordingMetadata(
                id: "same-transcript",
                date: date,
                durationSeconds: 95,
                transcriptPath: "/synthetic/meeting.md"
            ))
            database.queue.sync {}

            XCTAssertEqual(database.getAllRecordings().map(\.durationSeconds), [95])
            XCTAssertEqual(
                dailyActivity(at: databaseURL, date: "2026-04-05"),
                DailyActivity(count: 1, duration: 95)
            )
        }

        for suffix in ["", "-shm", "-wal"] {
            try? FileManager.default.removeItem(at: URL(fileURLWithPath: databaseURL.path + suffix))
        }
    }
}

private struct DailyActivity: Equatable {
    let count: Int
    let duration: Int
}

private func dailyActivity(at databaseURL: URL, date: String) -> DailyActivity? {
    var db: OpaquePointer?
    guard sqlite3_open(databaseURL.path, &db) == SQLITE_OK else { return nil }
    defer { sqlite3_close(db) }

    let sql = "SELECT recording_count, total_duration_seconds FROM daily_activity WHERE date = ? LIMIT 1;"
    var statement: OpaquePointer?
    guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK else { return nil }
    defer { sqlite3_finalize(statement) }

    sqlite3_bind_text(statement, 1, (date as NSString).utf8String, -1, unsafeBitCast(-1, to: sqlite3_destructor_type.self))
    guard sqlite3_step(statement) == SQLITE_ROW else { return nil }
    return DailyActivity(
        count: Int(sqlite3_column_int(statement, 0)),
        duration: Int(sqlite3_column_int(statement, 1))
    )
}
