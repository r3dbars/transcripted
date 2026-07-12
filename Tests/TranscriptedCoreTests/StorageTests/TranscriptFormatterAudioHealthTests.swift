import XCTest
@testable import TranscriptedCore

/// Issue #500 post-meeting surfacing: the formatter must emit the
/// `audio_health` / `mic_boost_prompt` keys as FLAT frontmatter lines, because
/// `TranscriptFrontmatter.values(from:)` skips indented lines — nested YAML
/// would be invisible to the app's Home scanner.
@available(macOS 14.0, *)
final class TranscriptFormatterAudioHealthTests: XCTestCase {
    func testMicAttenuationHealthInfoEmitsFlatAudioHealthKeys() {
        let markdown = TranscriptSaver.formatTranscriptMarkdown(
            result: makeResult(),
            transcriptId: UUID(uuidString: "00000000-0000-0000-0000-000000000500")!,
            date: Date(timeIntervalSince1970: 0),
            healthInfo: RecordingHealthInfo(
                captureQuality: .excellent,
                audioGaps: 0,
                deviceSwitches: 0,
                gapDescriptions: [],
                micAttenuatedByCallApp: true,
                micBoostPrompt: "declined"
            )
        )

        XCTAssertTrue(markdown.contains("\naudio_health: mic_attenuated_by_call_app"))
        XCTAssertTrue(markdown.contains("\nmic_boost_prompt: \"declined\""))

        // Flat-parse round-trip contract: the Home scanner reads these back
        // through the shared frontmatter parser.
        let values = TranscriptFrontmatter.document(in: markdown)?.values
        XCTAssertEqual(values?["audio_health"], "mic_attenuated_by_call_app")
        XCTAssertEqual(values?["mic_boost_prompt"], "declined")
    }

    func testHealthyMeetingEmitsNoAudioHealthKeys() {
        let markdown = TranscriptSaver.formatTranscriptMarkdown(
            result: makeResult(),
            transcriptId: UUID(uuidString: "00000000-0000-0000-0000-000000000501")!,
            date: Date(timeIntervalSince1970: 0),
            healthInfo: .perfect
        )

        XCTAssertFalse(markdown.contains("audio_health:"), "healthy meetings should not carry frontmatter noise")
        XCTAssertFalse(markdown.contains("mic_boost_prompt:"), "the prompt outcome only rides attenuated meetings")

        let values = TranscriptFrontmatter.document(in: markdown)?.values
        XCTAssertNil(values?["audio_health"])
        XCTAssertNil(values?["mic_boost_prompt"])
    }

    func testAttenuationWithoutPromptOutcomeOmitsThePromptKey() {
        let markdown = TranscriptSaver.formatTranscriptMarkdown(
            result: makeResult(),
            transcriptId: UUID(uuidString: "00000000-0000-0000-0000-000000000502")!,
            date: Date(timeIntervalSince1970: 0),
            healthInfo: RecordingHealthInfo(
                captureQuality: .good,
                audioGaps: 0,
                deviceSwitches: 0,
                gapDescriptions: [],
                micAttenuatedByCallApp: true,
                micBoostPrompt: nil
            )
        )

        let values = TranscriptFrontmatter.document(in: markdown)?.values
        XCTAssertEqual(values?["audio_health"], "mic_attenuated_by_call_app")
        XCTAssertNil(values?["mic_boost_prompt"], "a nil prompt outcome should omit the key entirely")
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
