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

    func testReplacingLegacyRecordingMatchesByTranscriptPath() {
        let databaseURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("TranscriptedCoreStatsTests-\(UUID().uuidString).sqlite")
        let date = Calendar(identifier: .gregorian).date(
            from: DateComponents(year: 2026, month: 4, day: 5, hour: 9, minute: 0)
        )!

        do {
            let database = StatsDatabase(path: databaseURL.path)
            database.recordSession(RecordingMetadata(
                id: "legacy-row-id",
                date: date,
                durationSeconds: 60,
                transcriptPath: "/synthetic/legacy-meeting.md"
            ))
            database.recordSession(RecordingMetadata(
                id: "fresh-replacement-id",
                date: date,
                durationSeconds: 95,
                transcriptPath: "/synthetic/legacy-meeting.md"
            ))
            database.queue.sync {}

            let recordings = database.getAllRecordings()
            XCTAssertEqual(recordings.map(\.id), ["legacy-row-id"])
            XCTAssertEqual(recordings.map(\.durationSeconds), [95])
            XCTAssertEqual(
                dailyActivity(at: databaseURL, date: "2026-04-05"),
                DailyActivity(count: 1, duration: 95)
            )
        }

        for suffix in ["", "-shm", "-wal"] {
            try? FileManager.default.removeItem(at: URL(fileURLWithPath: databaseURL.path + suffix))
        }
    }

    func testRecordingWriteFailureRollsBackDailyActivityUpdate() {
        let databaseURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("TranscriptedCoreStatsTests-\(UUID().uuidString).sqlite")
        let database = StatsDatabase(path: databaseURL.path)
        let authorizerResult = database.queue.sync {
            sqlite3_set_authorizer(database.db, { _, action, tableName, _, _, _ in
                guard action == SQLITE_INSERT,
                      let tableName,
                      String(cString: tableName) == "recordings" else {
                    return SQLITE_OK
                }
                return SQLITE_DENY
            }, nil)
        }
        XCTAssertEqual(authorizerResult, SQLITE_OK)
        defer {
            _ = database.queue.sync { sqlite3_set_authorizer(database.db, nil, nil) }
            for suffix in ["", "-shm", "-wal"] {
                try? FileManager.default.removeItem(at: URL(fileURLWithPath: databaseURL.path + suffix))
            }
        }

        database.recordSession(RecordingMetadata(
            id: "denied-recording",
            date: Calendar(identifier: .gregorian).date(
                from: DateComponents(year: 2026, month: 4, day: 8, hour: 9, minute: 0)
            )!,
            durationSeconds: 120
        ))
        database.queue.sync {}

        XCTAssertTrue(database.getAllRecordings().isEmpty)
        XCTAssertNil(dailyActivity(at: databaseURL, date: "2026-04-08"))
    }

    func testRecordingLookupErrorAbortsReplacement() {
        let databaseURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("TranscriptedCoreStatsTests-\(UUID().uuidString).sqlite")
        let database = StatsDatabase(path: databaseURL.path)
        let date = Calendar(identifier: .gregorian).date(
            from: DateComponents(year: 2026, month: 4, day: 9, hour: 9, minute: 0)
        )!
        defer {
            _ = database.queue.sync { sqlite3_set_authorizer(database.db, nil, nil) }
            for suffix in ["", "-shm", "-wal"] {
                try? FileManager.default.removeItem(at: URL(fileURLWithPath: databaseURL.path + suffix))
            }
        }

        database.recordSession(RecordingMetadata(
            id: "lookup-error",
            date: date,
            durationSeconds: 60
        ))
        database.queue.sync {}

        let authorizerResult = database.queue.sync {
            sqlite3_set_authorizer(database.db, { _, action, tableName, _, _, _ in
                guard action == SQLITE_READ,
                      let tableName,
                      String(cString: tableName) == "recordings" else {
                    return SQLITE_OK
                }
                return SQLITE_DENY
            }, nil)
        }
        XCTAssertEqual(authorizerResult, SQLITE_OK)

        database.recordSession(RecordingMetadata(
            id: "lookup-error",
            date: date,
            durationSeconds: 95
        ))
        database.queue.sync {}
        _ = database.queue.sync { sqlite3_set_authorizer(database.db, nil, nil) }

        XCTAssertEqual(database.getAllRecordings().map(\.durationSeconds), [60])
        XCTAssertEqual(
            dailyActivity(at: databaseURL, date: "2026-04-09"),
            DailyActivity(count: 1, duration: 60)
        )
    }

    func testDailyActivityWriteFailureRollsBackInsertedRecording() {
        let databaseURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("TranscriptedCoreStatsTests-\(UUID().uuidString).sqlite")
        let database = StatsDatabase(path: databaseURL.path)
        let authorizerResult = database.queue.sync {
            sqlite3_set_authorizer(database.db, { _, action, tableName, _, _, _ in
                guard action == SQLITE_INSERT,
                      let tableName,
                      String(cString: tableName) == "daily_activity" else {
                    return SQLITE_OK
                }
                return SQLITE_DENY
            }, nil)
        }
        XCTAssertEqual(authorizerResult, SQLITE_OK)
        defer {
            _ = database.queue.sync { sqlite3_set_authorizer(database.db, nil, nil) }
            for suffix in ["", "-shm", "-wal"] {
                try? FileManager.default.removeItem(at: URL(fileURLWithPath: databaseURL.path + suffix))
            }
        }

        database.recordSession(RecordingMetadata(
            id: "daily-write-error",
            date: Calendar(identifier: .gregorian).date(
                from: DateComponents(year: 2026, month: 4, day: 10, hour: 9, minute: 0)
            )!,
            durationSeconds: 120
        ))
        database.queue.sync {}
        _ = database.queue.sync { sqlite3_set_authorizer(database.db, nil, nil) }

        XCTAssertTrue(database.getAllRecordings().isEmpty)
        XCTAssertNil(dailyActivity(at: databaseURL, date: "2026-04-10"))
        XCTAssertEqual(database.queue.sync { sqlite3_get_autocommit(database.db) }, 1)
    }

    func testRollbackFailureQuarantinesConnectionAndDiscardsTransaction() {
        let databaseURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("TranscriptedCoreStatsTests-\(UUID().uuidString).sqlite")
        let database = StatsDatabase(path: databaseURL.path)
        let authorizerResult = database.queue.sync {
            sqlite3_set_authorizer(database.db, { _, action, firstArgument, _, _, _ in
                if action == SQLITE_INSERT,
                   let firstArgument,
                   String(cString: firstArgument) == "daily_activity" {
                    return SQLITE_DENY
                }
                if action == SQLITE_TRANSACTION,
                   let firstArgument,
                   String(cString: firstArgument) == "ROLLBACK" {
                    return SQLITE_DENY
                }
                return SQLITE_OK
            }, nil)
        }
        XCTAssertEqual(authorizerResult, SQLITE_OK)
        defer {
            for suffix in ["", "-shm", "-wal"] {
                try? FileManager.default.removeItem(at: URL(fileURLWithPath: databaseURL.path + suffix))
            }
        }

        database.recordSession(RecordingMetadata(
            id: "rollback-error",
            date: Calendar(identifier: .gregorian).date(
                from: DateComponents(year: 2026, month: 4, day: 11, hour: 9, minute: 0)
            )!,
            durationSeconds: 120
        ))
        database.queue.sync {}

        XCTAssertFalse(database.isDatabaseOpen)
        XCTAssertNil(database.db)
        XCTAssertEqual(recordingCount(at: databaseURL), 0)
        XCTAssertNil(dailyActivity(at: databaseURL, date: "2026-04-11"))
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

private func recordingCount(at databaseURL: URL) -> Int? {
    var db: OpaquePointer?
    guard sqlite3_open(databaseURL.path, &db) == SQLITE_OK else { return nil }
    defer { sqlite3_close(db) }

    var statement: OpaquePointer?
    guard sqlite3_prepare_v2(db, "SELECT COUNT(*) FROM recordings;", -1, &statement, nil) == SQLITE_OK else {
        return nil
    }
    defer { sqlite3_finalize(statement) }

    guard sqlite3_step(statement) == SQLITE_ROW else { return nil }
    return Int(sqlite3_column_int(statement, 0))
}
