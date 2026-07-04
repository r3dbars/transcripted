import XCTest
import SQLite3
@testable import TranscriptedCore

@available(macOS 14.0, *)
final class StatsDatabaseQueriesTests: XCTestCase {

    private func makeTempDatabaseURL() -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("TranscriptedCoreStatsQueriesTests-\(UUID().uuidString).sqlite")
    }

    private func cleanup(_ url: URL) {
        for suffix in ["", "-shm", "-wal"] {
            try? FileManager.default.removeItem(at: URL(fileURLWithPath: url.path + suffix))
        }
    }

    func testGetRecordingsFiltersByDateRangeInclusive() {
        let databaseURL = makeTempDatabaseURL()
        let calendar = Calendar(identifier: .gregorian)
        func date(_ day: Int) -> Date {
            calendar.date(from: DateComponents(year: 2026, month: 4, day: day, hour: 9, minute: 0))!
        }

        do {
            let database = StatsDatabase(path: databaseURL.path)
            database.recordSession(RecordingMetadata(id: "day4", date: date(4), durationSeconds: 10))
            database.recordSession(RecordingMetadata(id: "day5", date: date(5), durationSeconds: 20))
            database.recordSession(RecordingMetadata(id: "day6", date: date(6), durationSeconds: 30))
            database.recordSession(RecordingMetadata(id: "day7", date: date(7), durationSeconds: 40))
            database.queue.sync {}

            let results = database.getRecordings(from: date(5), to: date(6))
            XCTAssertEqual(results.map(\.id), ["day6", "day5"])

            let allResults = database.getRecordings(from: date(4), to: date(7))
            XCTAssertEqual(allResults.map(\.id), ["day7", "day6", "day5", "day4"])

            let noResults = database.getRecordings(from: date(1), to: date(2))
            XCTAssertTrue(noResults.isEmpty)
        }

        cleanup(databaseURL)
    }

    func testGetDailyActivityGroupsByDateWithinMonthAndExcludesOtherMonths() {
        let databaseURL = makeTempDatabaseURL()
        let calendar = Calendar(identifier: .gregorian)
        func date(_ month: Int, _ day: Int) -> Date {
            calendar.date(from: DateComponents(year: 2026, month: month, day: day, hour: 9, minute: 0))!
        }

        do {
            let database = StatsDatabase(path: databaseURL.path)
            database.recordSession(RecordingMetadata(id: "march-31", date: date(3, 31), durationSeconds: 500))
            database.recordSession(RecordingMetadata(id: "april-5a", date: date(4, 5), durationSeconds: 60))
            database.recordSession(RecordingMetadata(id: "april-5b", date: date(4, 5), durationSeconds: 90))
            database.recordSession(RecordingMetadata(id: "april-6", date: date(4, 6), durationSeconds: 300))
            database.queue.sync {}

            let activity = database.getDailyActivity(for: date(4, 15))

            XCTAssertNil(activity["2026-03-31"])
            XCTAssertNil(activity["2026-04-07"])

            let april5 = try XCTUnwrap(activity["2026-04-05"])
            XCTAssertEqual(april5.recordingCount, 2)
            XCTAssertEqual(april5.totalDurationSeconds, 150)
            XCTAssertEqual(april5.actionItemsCount, 0)

            let april6 = try XCTUnwrap(activity["2026-04-06"])
            XCTAssertEqual(april6.recordingCount, 1)
            XCTAssertEqual(april6.totalDurationSeconds, 300)
        } catch {
            XCTFail("Unexpected error: \(error)")
        }

        cleanup(databaseURL)
    }

    func testGetAllActiveDatesReturnsDescendingDatesWithActivity() {
        let databaseURL = makeTempDatabaseURL()
        let calendar = Calendar(identifier: .gregorian)
        func date(_ day: Int) -> Date {
            calendar.date(from: DateComponents(year: 2026, month: 4, day: day, hour: 9, minute: 0))!
        }

        do {
            let database = StatsDatabase(path: databaseURL.path)
            database.recordSession(RecordingMetadata(id: "day5", date: date(5), durationSeconds: 10))
            database.recordSession(RecordingMetadata(id: "day6", date: date(6), durationSeconds: 10))
            database.recordSession(RecordingMetadata(id: "day7", date: date(7), durationSeconds: 10))
            database.queue.sync {}

            XCTAssertEqual(database.getAllActiveDates(), ["2026-04-07", "2026-04-06", "2026-04-05"])
        }

        cleanup(databaseURL)
    }

    func testTotalRecordingsAndDurationAggregates() {
        let databaseURL = makeTempDatabaseURL()
        let calendar = Calendar(identifier: .gregorian)
        func date(_ day: Int) -> Date {
            calendar.date(from: DateComponents(year: 2026, month: 4, day: day, hour: 9, minute: 0))!
        }

        do {
            let database = StatsDatabase(path: databaseURL.path)
            XCTAssertEqual(database.getTotalRecordingsCount(), 0)
            XCTAssertEqual(database.getTotalDurationSeconds(), 0)

            database.recordSession(RecordingMetadata(id: "a", date: date(5), durationSeconds: 60))
            database.recordSession(RecordingMetadata(id: "b", date: date(6), durationSeconds: 120))
            database.recordSession(RecordingMetadata(id: "c", date: date(7), durationSeconds: 180))
            database.queue.sync {}

            XCTAssertEqual(database.getTotalRecordingsCount(), 3)
            XCTAssertEqual(database.getTotalDurationSeconds(), 360)
        }

        cleanup(databaseURL)
    }

    func testGetStatsForLastDaysWindowsRelativeToToday() {
        let databaseURL = makeTempDatabaseURL()
        let calendar = Calendar.current
        let now = Date()
        let threeDaysAgo = calendar.date(byAdding: .day, value: -3, to: now)!
        let tenDaysAgo = calendar.date(byAdding: .day, value: -10, to: now)!

        do {
            let database = StatsDatabase(path: databaseURL.path)
            database.recordSession(RecordingMetadata(id: "today", date: now, durationSeconds: 100))
            database.recordSession(RecordingMetadata(id: "three-days-ago", date: threeDaysAgo, durationSeconds: 200))
            database.recordSession(RecordingMetadata(id: "ten-days-ago", date: tenDaysAgo, durationSeconds: 300))
            database.queue.sync {}

            let todayOnly = database.getStatsForLastDays(0)
            XCTAssertEqual(todayOnly.recordings, 1)
            XCTAssertEqual(todayOnly.durationSeconds, 100)

            let lastWeek = database.getStatsForLastDays(7)
            XCTAssertEqual(lastWeek.recordings, 2)
            XCTAssertEqual(lastWeek.durationSeconds, 300)

            let lastMonth = database.getStatsForLastDays(30)
            XCTAssertEqual(lastMonth.recordings, 3)
            XCTAssertEqual(lastMonth.durationSeconds, 600)
        }

        cleanup(databaseURL)
    }

    func testRecordingExistsByTranscriptPathAndId() {
        let databaseURL = makeTempDatabaseURL()
        let calendar = Calendar(identifier: .gregorian)
        let date = calendar.date(from: DateComponents(year: 2026, month: 4, day: 5, hour: 9, minute: 0))!

        do {
            let database = StatsDatabase(path: databaseURL.path)
            database.recordSession(RecordingMetadata(
                id: "rec-1",
                date: date,
                durationSeconds: 60,
                transcriptPath: "/synthetic/exists.md"
            ))
            database.queue.sync {}

            XCTAssertTrue(database.recordingExists(transcriptPath: "/synthetic/exists.md"))
            XCTAssertFalse(database.recordingExists(transcriptPath: "/synthetic/missing.md"))
            XCTAssertTrue(database.recordingExists(id: "rec-1"))
            XCTAssertFalse(database.recordingExists(id: "missing-id"))
        }

        cleanup(databaseURL)
    }

    func testClearAllDataEmptiesRecordingsAndDailyActivity() {
        let databaseURL = makeTempDatabaseURL()
        let calendar = Calendar(identifier: .gregorian)
        func date(_ day: Int) -> Date {
            calendar.date(from: DateComponents(year: 2026, month: 4, day: day, hour: 9, minute: 0))!
        }

        do {
            let database = StatsDatabase(path: databaseURL.path)
            database.recordSession(RecordingMetadata(id: "a", date: date(5), durationSeconds: 60))
            database.recordSession(RecordingMetadata(id: "b", date: date(6), durationSeconds: 90))
            database.queue.sync {}
            XCTAssertEqual(database.getTotalRecordingsCount(), 2)

            database.clearAllData()
            database.queue.sync {}

            XCTAssertEqual(database.getTotalRecordingsCount(), 0)
            XCTAssertEqual(database.getTotalDurationSeconds(), 0)
            XCTAssertTrue(database.getAllRecordings().isEmpty)
            XCTAssertTrue(database.getAllActiveDates().isEmpty)
            XCTAssertTrue(database.getDailyActivity(for: date(15)).isEmpty)
        }

        cleanup(databaseURL)
    }
}
