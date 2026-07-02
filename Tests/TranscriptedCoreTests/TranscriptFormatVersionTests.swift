import XCTest
@testable import TranscriptedCore

/// Capture-format contract (docs/capture-format.md): the formatter stamps every
/// meeting save with flat `format_version: 1` and `transcript_style: raw`
/// frontmatter keys. Absent keys mean a pre-versioning file, so these must be
/// emitted on every save and stay readable through the shared flat-line parser
/// the Home scanner uses.
@available(macOS 14.0, *)
final class TranscriptFormatVersionTests: XCTestCase {
    func testMeetingSaveEmitsFlatFormatVersionAndRawStyle() {
        let markdown = TranscriptSaver.formatTranscriptMarkdown(
            result: makeResult(),
            transcriptId: UUID(uuidString: "00000000-0000-0000-0000-000000000600")!,
            date: Date(timeIntervalSince1970: 0)
        )

        XCTAssertTrue(markdown.contains("\nformat_version: 1\n"))
        XCTAssertTrue(markdown.contains("\ntranscript_style: raw\n"))

        // Flat-parse round-trip contract: TranscriptFrontmatter.values(from:)
        // skips indented lines, so the keys must land at the top level.
        let values = TranscriptFrontmatter.document(in: markdown)?.values
        XCTAssertEqual(values?["format_version"], "1")
        XCTAssertEqual(values?["transcript_style"], "raw")
    }

    func testFormatVersionSurvivesHealthAndSpeakerMetadata() {
        let markdown = TranscriptSaver.formatTranscriptMarkdown(
            result: makeResult(),
            transcriptId: UUID(uuidString: "00000000-0000-0000-0000-000000000601")!,
            speakerMappings: [
                "system_0": SpeakerMapping(speakerId: "0", identifiedName: "Alex", confidence: .high)
            ],
            speakerSources: ["system_0": "db_scan"],
            date: Date(timeIntervalSince1970: 0),
            meetingTitle: "Format contract check",
            healthInfo: RecordingHealthInfo(
                captureQuality: .good,
                audioGaps: 1,
                deviceSwitches: 0,
                gapDescriptions: ["Audio gap at 00:42 (1.5s)"],
                micAttenuatedByCallApp: nil,
                micBoostPrompt: nil
            )
        )

        let values = TranscriptFrontmatter.document(in: markdown)?.values
        XCTAssertEqual(values?["format_version"], "1")
        XCTAssertEqual(values?["transcript_style"], "raw")
        XCTAssertEqual(values?["capture_type"], "meeting")
        XCTAssertEqual(values?["title"], "Format contract check")
    }

    private func makeResult() -> TranscriptionResult {
        TranscriptionResult(
            micUtterances: [],
            systemUtterances: [
                TranscriptionUtterance(
                    start: 0,
                    end: 2,
                    channel: 1,
                    speakerId: 0,
                    persistentSpeakerId: nil,
                    matchSimilarity: nil,
                    transcript: "Thanks for joining."
                )
            ],
            duration: 2,
            processingTime: 0.5
        )
    }
}
