import XCTest
@testable import TranscriptedCore

@available(macOS 14.0, *)
@MainActor
final class StatsServiceTests: XCTestCase {

    func testFormatDurationCompactBoundaryValues() {
        XCTAssertEqual(StatsService.formatDurationCompact(0), "0m")
        XCTAssertEqual(StatsService.formatDurationCompact(59), "0m")
        XCTAssertEqual(StatsService.formatDurationCompact(60), "1m")
        XCTAssertEqual(StatsService.formatDurationCompact(3599), "59m")
        XCTAssertEqual(StatsService.formatDurationCompact(3600), "1h")
        XCTAssertEqual(StatsService.formatDurationCompact(5400), "1.5h")
        XCTAssertEqual(StatsService.formatDurationCompact(7200), "2h")
    }

    func testCreateMetadataAggregatesWordAndSpeakerCountsAcrossChannels() {
        let captureId = UUID()
        let date = Date(timeIntervalSince1970: 1_700_000_000)

        let micUtterances = [
            TranscriptionUtterance(
                start: 0, end: 1, channel: 0, speakerId: 0,
                persistentSpeakerId: nil, matchSimilarity: nil, transcript: "hello world"
            ),
            TranscriptionUtterance(
                start: 1, end: 2, channel: 0, speakerId: 1,
                persistentSpeakerId: nil, matchSimilarity: nil, transcript: "foo"
            )
        ]
        let systemUtterances = [
            TranscriptionUtterance(
                start: 0, end: 1, channel: 1, speakerId: 0,
                persistentSpeakerId: nil, matchSimilarity: nil, transcript: "bar baz qux"
            )
        ]
        let result = TranscriptionResult(
            micUtterances: micUtterances,
            systemUtterances: systemUtterances,
            duration: 125.7,
            processingTime: 2.5
        )

        let metadata = StatsService.createMetadata(
            from: result,
            captureId: captureId,
            transcriptPath: "/tmp/out.md",
            title: "Standup",
            date: date
        )

        XCTAssertEqual(metadata.id, captureId.uuidString)
        XCTAssertEqual(metadata.date, date)
        XCTAssertEqual(metadata.durationSeconds, 125)
        XCTAssertEqual(metadata.wordCount, 6)
        XCTAssertEqual(metadata.speakerCount, 3)
        XCTAssertEqual(metadata.processingTimeMs, 2500)
        XCTAssertEqual(metadata.transcriptPath, "/tmp/out.md")
        XCTAssertEqual(metadata.title, "Standup")
    }

    func testCreateMetadataAllowsNilTranscriptPathAndTitleAndDefaultsDate() {
        let captureId = UUID()
        let result = TranscriptionResult(micUtterances: [], systemUtterances: [], duration: 10, processingTime: 0)

        let before = Date()
        let metadata = StatsService.createMetadata(
            from: result,
            captureId: captureId,
            transcriptPath: nil,
            title: nil
        )
        let after = Date()

        XCTAssertEqual(metadata.wordCount, 0)
        XCTAssertEqual(metadata.speakerCount, 0)
        XCTAssertNil(metadata.transcriptPath)
        XCTAssertNil(metadata.title)
        XCTAssertTrue(metadata.date >= before && metadata.date <= after)
    }
}
