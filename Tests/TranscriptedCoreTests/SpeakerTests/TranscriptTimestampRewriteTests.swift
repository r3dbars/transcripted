import XCTest
@testable import TranscriptedCore

final class TranscriptTimestampRewriteTests: XCTestCase {
    func testRenameAcceptsLegacyAndHourClocksWithoutChangingTheirSpelling() {
        let clocks: [(String, Double)] = [
            ("59:59", 3599.99), ("60:00", 3600), ("1:00:00", 3600),
            ("01:00:00", 3600.99), ("125:30", 7530), ("02:05:30", 7530),
            ("24:00:00", 86400), ("6000:00", 360000), ("100:00:00", 360000),
        ]
        for styled in [false, true] {
            for (clock, start) in clocks {
                var markdown = document(clock: clock, styled: styled)
                let expected = markdown.replacingOccurrences(of: "[System/Original]", with: "[System/Updated]")
                XCTAssertTrue(rewrite(&markdown, utterances: [utterance(start)]), clock)
                XCTAssertEqual(markdown, expected, clock)
            }
        }
    }

    func testRenameRejectsMalformedOrWrongOffsetsWithoutChangingTheDocument() {
        for styled in [false, true] {
            for clock in ["01:00:01", "1:60:00", "00:60", "1::00", "١:00:00", "9999999999999999999:00", "2562047788015216:00:00"] {
                var markdown = document(clock: clock, styled: styled)
                let original = markdown
                XCTAssertFalse(rewrite(&markdown, utterances: [utterance(3600)]), clock)
                XCTAssertEqual(markdown, original, clock)
            }
        }
    }

    func testTextOutsideTheTimestampGrammarIsNeverRenamed() {
        for styled in [false, true] {
            for clock in ["-1:00", "1:0.0:00"] {
                var markdown = document(clock: clock, styled: styled)
                let original = markdown
                // The styled reader preserves non-row text; it may report a
                // successful no-op when there are no recognized rows.
                _ = rewrite(&markdown, utterances: [utterance(3600)])
                XCTAssertEqual(markdown, original, clock)
            }
        }
    }

    func testRenameStillRequiresMatchingChannelsAndOrderedRows() {
        for styled in [false, true] {
            var wrongChannel = document(clock: "01:00:00", styled: styled)
            let original = wrongChannel
            XCTAssertFalse(rewrite(&wrongChannel, utterances: [utterance(3600, channel: 0)]))
            XCTAssertEqual(wrongChannel, original)

            var reversed = document(rows: [row("01:00:01", styled: styled), row("60:00", styled: styled)], styled: styled)
            let before = reversed
            XCTAssertFalse(rewrite(&reversed, utterances: [utterance(3600), utterance(3601)]))
            XCTAssertEqual(reversed, before)
        }
    }

    func testStyledSameSecondAmbiguityStillRefusesDifferentSpeakerNames() {
        var markdown = document(clock: "01:00:00", styled: true)
        let original = markdown
        XCTAssertFalse(rewrite(&markdown, utterances: [utterance(3600.2), utterance(3600.7, speaker: 1)]))
        XCTAssertEqual(markdown, original)
    }

    func testStyledOmittedWhitespaceRowDoesNotShiftHourClockSpeaker() {
        var markdown = document(clock: "01:00:01", styled: true)
        let expected = markdown.replacingOccurrences(of: "[System/Original]", with: "[System/Other]")
        XCTAssertTrue(rewrite(&markdown, utterances: [utterance(3600, text: "  "), utterance(3601, speaker: 1)]))
        XCTAssertEqual(markdown, expected)
    }

    func testRawSameSecondRowsKeepTheirOrderedSpeakerIdentities() {
        var markdown = document(rows: [row("60:00", styled: false), row("01:00:00", styled: false)], styled: false)
        let expected = document(rows: [row("60:00", styled: false, label: "Updated"), row("01:00:00", styled: false, label: "Other")], styled: false)
        XCTAssertTrue(rewrite(&markdown, utterances: [utterance(3600.2), utterance(3600.7, speaker: 1)]))
        XCTAssertEqual(markdown, expected)
    }

    private func rewrite(_ markdown: inout String, utterances: [TranscriptionUtterance]) -> Bool {
        let result = TranscriptionResult(
            micUtterances: utterances.filter { $0.channel == 0 },
            systemUtterances: utterances.filter { $0.channel == 1 },
            duration: (utterances.last?.end ?? 0) + 1, processingTime: 1
        )
        return TranscriptSaver.rewriteFullTranscriptSection(
            in: &markdown, result: result,
            updatesByChannelKey: ["system_0": ("Original", "Updated"), "system_1": ("Original", "Other")],
            obsidianEnabled: false
        )
    }

    private func utterance(_ start: Double, channel: Int = 1, speaker: Int = 0, text: String = "Synthetic text.") -> TranscriptionUtterance {
        TranscriptionUtterance(start: start, end: start + 1, channel: channel, speakerId: speaker,
                               persistentSpeakerId: nil, matchSimilarity: nil, transcript: text)
    }

    private func row(_ clock: String, styled: Bool, label: String = "Original") -> String {
        styled ? "**\(clock)**  [System/\(label)]\nSynthetic text." : "[\(clock)] [System/\(label)] Synthetic text."
    }

    private func document(clock: String, styled: Bool) -> String {
        document(rows: [row(clock, styled: styled)], styled: styled)
    }

    private func document(rows: [String], styled: Bool) -> String {
        "## \(styled ? "Transcript" : "Full Transcript")\n\n" + rows.joined(separator: "\n\n") + "\n\n---\n\n*Generated by Transcripted*\n"
    }
}
