import XCTest
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
}
