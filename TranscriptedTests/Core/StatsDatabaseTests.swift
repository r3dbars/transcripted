import XCTest
@testable import Transcripted

@available(macOS 14.0, *)
final class StatsDatabaseTests: XCTestCase {

    // MARK: - RecordingMetadata.formattedDuration

    func testFormattedDurationMinutesOnly() {
        let metadata = makeMetadata(durationSeconds: 300) // 5 min
        XCTAssertEqual(metadata.formattedDuration, "5m")
    }

    func testFormattedDurationHoursAndMinutes() {
        let metadata = makeMetadata(durationSeconds: 3900) // 1h 5m
        XCTAssertEqual(metadata.formattedDuration, "1h 5m")
    }

    func testFormattedDurationZeroSeconds() {
        let metadata = makeMetadata(durationSeconds: 0)
        XCTAssertEqual(metadata.formattedDuration, "0m")
    }

    func testFormattedDurationLessThanOneMinute() {
        let metadata = makeMetadata(durationSeconds: 45)
        XCTAssertEqual(metadata.formattedDuration, "0m")
    }

    func testFormattedDurationExactHour() {
        let metadata = makeMetadata(durationSeconds: 3600)
        XCTAssertEqual(metadata.formattedDuration, "1h 0m")
    }

    func testFormattedDurationMultipleHours() {
        let metadata = makeMetadata(durationSeconds: 9000) // 2h 30m
        XCTAssertEqual(metadata.formattedDuration, "2h 30m")
    }

    // MARK: - RecordingMetadata.displayTitle

    func testDisplayTitleWithTitle() {
        let metadata = makeMetadata(title: "Weekly Standup")
        XCTAssertEqual(metadata.displayTitle, "Weekly Standup")
    }

    func testDisplayTitleWithEmptyTitle() {
        let metadata = makeMetadata(title: "")
        // Empty title falls back to date-based display
        XCTAssertTrue(metadata.displayTitle.hasPrefix("Recording - "))
    }

    func testDisplayTitleWithNilTitle() {
        let metadata = makeMetadata(title: nil)
        XCTAssertTrue(metadata.displayTitle.hasPrefix("Recording - "))
    }

    // MARK: - DailyActivity.intensityLevel

    func testIntensityLevelZeroRecordings() {
        let activity = DailyActivity(date: "2026-03-01", recordingCount: 0, totalDurationSeconds: 0, actionItemsCount: 0)
        XCTAssertEqual(activity.intensityLevel, 0)
    }

    func testIntensityLevelOneRecording() {
        let activity = DailyActivity(date: "2026-03-01", recordingCount: 1, totalDurationSeconds: 600, actionItemsCount: 0)
        XCTAssertEqual(activity.intensityLevel, 1)
    }

    func testIntensityLevelTwoRecordings() {
        let activity = DailyActivity(date: "2026-03-01", recordingCount: 2, totalDurationSeconds: 1200, actionItemsCount: 0)
        XCTAssertEqual(activity.intensityLevel, 2)
    }

    func testIntensityLevelThreeRecordings() {
        let activity = DailyActivity(date: "2026-03-01", recordingCount: 3, totalDurationSeconds: 1800, actionItemsCount: 0)
        XCTAssertEqual(activity.intensityLevel, 2)
    }

    func testIntensityLevelFourRecordings() {
        let activity = DailyActivity(date: "2026-03-01", recordingCount: 4, totalDurationSeconds: 2400, actionItemsCount: 0)
        XCTAssertEqual(activity.intensityLevel, 3)
    }

    func testIntensityLevelFiveRecordings() {
        let activity = DailyActivity(date: "2026-03-01", recordingCount: 5, totalDurationSeconds: 3000, actionItemsCount: 0)
        XCTAssertEqual(activity.intensityLevel, 3)
    }

    func testIntensityLevelSixPlusRecordings() {
        let activity = DailyActivity(date: "2026-03-01", recordingCount: 10, totalDurationSeconds: 6000, actionItemsCount: 0)
        XCTAssertEqual(activity.intensityLevel, 4)
    }

    // MARK: - DailyActivity.formattedDuration

    func testDailyActivityFormattedDurationMinutes() {
        let activity = DailyActivity(date: "2026-03-01", recordingCount: 2, totalDurationSeconds: 1500, actionItemsCount: 0)
        XCTAssertEqual(activity.formattedDuration, "25m")
    }

    func testDailyActivityFormattedDurationHoursMinutes() {
        let activity = DailyActivity(date: "2026-03-01", recordingCount: 5, totalDurationSeconds: 5400, actionItemsCount: 0)
        XCTAssertEqual(activity.formattedDuration, "1h 30m")
    }

    func testDailyActivityFormattedDurationZero() {
        let activity = DailyActivity(date: "2026-03-01", recordingCount: 0, totalDurationSeconds: 0, actionItemsCount: 0)
        XCTAssertEqual(activity.formattedDuration, "0m")
    }

    // MARK: - RecordingMetadata defaults

    func testRecordingMetadataDefaultId() {
        let m1 = makeMetadata()
        let m2 = makeMetadata()
        XCTAssertNotEqual(m1.id, m2.id, "Each metadata should get a unique UUID")
    }

    func testRecordingMetadataDefaultValues() {
        let metadata = RecordingMetadata(date: Date(), durationSeconds: 60)
        XCTAssertEqual(metadata.wordCount, 0)
        XCTAssertEqual(metadata.speakerCount, 0)
        XCTAssertEqual(metadata.processingTimeMs, 0)
        XCTAssertNil(metadata.transcriptPath)
        XCTAssertNil(metadata.title)
    }

    // MARK: - Helpers

    private func makeMetadata(
        durationSeconds: Int = 600,
        title: String? = "Test Recording"
    ) -> RecordingMetadata {
        RecordingMetadata(
            date: Date(),
            durationSeconds: durationSeconds,
            wordCount: 1000,
            speakerCount: 2,
            processingTimeMs: 5000,
            title: title
        )
    }
}
