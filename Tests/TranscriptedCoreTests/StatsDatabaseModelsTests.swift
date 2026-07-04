import XCTest
@testable import TranscriptedCore

@available(macOS 14.0, *)
final class StatsDatabaseModelsTests: XCTestCase {

    func testRecordingMetadataDefaultIdIsAValidUUIDString() {
        let metadata = RecordingMetadata(date: Date(), durationSeconds: 60)
        XCTAssertNotNil(UUID(uuidString: metadata.id))
    }

    func testRecordingMetadataFormattedDuration() {
        XCTAssertEqual(RecordingMetadata(date: Date(), durationSeconds: 0).formattedDuration, "0m")
        XCTAssertEqual(RecordingMetadata(date: Date(), durationSeconds: 125).formattedDuration, "2m")
        XCTAssertEqual(RecordingMetadata(date: Date(), durationSeconds: 3661).formattedDuration, "1h 1m")
    }

    func testRecordingMetadataDisplayTitlePrefersNonEmptyTitle() {
        let metadata = RecordingMetadata(date: Date(), durationSeconds: 60, title: "Standup")
        XCTAssertEqual(metadata.displayTitle, "Standup")
    }

    func testRecordingMetadataDisplayTitleFallsBackToDateWhenTitleIsNilOrEmpty() {
        let nilTitle = RecordingMetadata(date: Date(), durationSeconds: 60, title: nil)
        XCTAssertTrue(nilTitle.displayTitle.hasPrefix("Recording - "))

        let emptyTitle = RecordingMetadata(date: Date(), durationSeconds: 60, title: "")
        XCTAssertTrue(emptyTitle.displayTitle.hasPrefix("Recording - "))
    }

    func testDailyActivityIntensityLevelBuckets() {
        XCTAssertEqual(DailyActivity(date: "2026-04-05", recordingCount: 0, totalDurationSeconds: 0, actionItemsCount: 0).intensityLevel, 0)
        XCTAssertEqual(DailyActivity(date: "2026-04-05", recordingCount: 1, totalDurationSeconds: 0, actionItemsCount: 0).intensityLevel, 1)
        XCTAssertEqual(DailyActivity(date: "2026-04-05", recordingCount: 2, totalDurationSeconds: 0, actionItemsCount: 0).intensityLevel, 2)
        XCTAssertEqual(DailyActivity(date: "2026-04-05", recordingCount: 3, totalDurationSeconds: 0, actionItemsCount: 0).intensityLevel, 2)
        XCTAssertEqual(DailyActivity(date: "2026-04-05", recordingCount: 4, totalDurationSeconds: 0, actionItemsCount: 0).intensityLevel, 3)
        XCTAssertEqual(DailyActivity(date: "2026-04-05", recordingCount: 5, totalDurationSeconds: 0, actionItemsCount: 0).intensityLevel, 3)
        XCTAssertEqual(DailyActivity(date: "2026-04-05", recordingCount: 6, totalDurationSeconds: 0, actionItemsCount: 0).intensityLevel, 4)
        XCTAssertEqual(DailyActivity(date: "2026-04-05", recordingCount: 100, totalDurationSeconds: 0, actionItemsCount: 0).intensityLevel, 4)
    }

    func testDailyActivityFormattedDuration() {
        XCTAssertEqual(DailyActivity(date: "2026-04-05", recordingCount: 1, totalDurationSeconds: 0, actionItemsCount: 0).formattedDuration, "0m")
        XCTAssertEqual(DailyActivity(date: "2026-04-05", recordingCount: 1, totalDurationSeconds: 125, actionItemsCount: 0).formattedDuration, "2m")
        XCTAssertEqual(DailyActivity(date: "2026-04-05", recordingCount: 1, totalDurationSeconds: 3661, actionItemsCount: 0).formattedDuration, "1h 1m")
    }
}
