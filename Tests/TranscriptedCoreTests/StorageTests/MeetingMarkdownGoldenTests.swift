import XCTest
@testable import TranscriptedCore

/// Output tests (Tests/README.md, "Test rules"): render a few canned meetings
/// through the real formatter and compare the whole Markdown file to an
/// approved copy in Tests/Fixtures/golden-meetings/. The saved Markdown is the
/// product that people, the MCP server and the CLI read, so any change to it
/// should show up as a plain-text diff in review instead of slipping through
/// a handful of `contains` checks.
///
/// Changed the format on purpose? Regenerate the approved copies and review
/// the diff like any other change:
///
///     TRANSCRIPTED_UPDATE_GOLDENS=1 swift test --filter MeetingMarkdownGoldenTests
///
/// Dates and times are written in the machine's time zone and locale, so the
/// exact strings the helpers produce for the fixed instant are swapped for
/// {{placeholders}} before comparing. Everything else must match byte for byte.
final class MeetingMarkdownGoldenTests: XCTestCase {
    private static let goldenDirectory = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent() // MeetingMarkdownGoldenTests.swift
        .deletingLastPathComponent() // StorageTests
        .deletingLastPathComponent() // TranscriptedCoreTests
        .appendingPathComponent("Fixtures/golden-meetings")

    /// 2026-09-21 14:13:20 UTC. Any fixed instant works; this one can't put a
    /// local hour of 00 or 01 next to the short [mm:ss] body timestamps.
    private static let meetingDate = Date(timeIntervalSince1970: 1_790_000_000)
    private static let importedDate = Date(timeIntervalSince1970: 1_790_086_400)

    func testTwoPersonCallMatchesApprovedMarkdown() throws {
        let result = TranscriptionResult(
            micUtterances: [
                utterance(0.0, 3.2, channel: 0, speaker: 0, "Thanks for making time today."),
                utterance(9.5, 12.0, channel: 0, speaker: 0, "That works. Let's ship it Friday."),
            ],
            systemUtterances: [
                utterance(3.8, 9.1, channel: 1, speaker: 0, "Happy to. I looked at the draft and have two notes."),
                utterance(12.4, 15.0, channel: 1, speaker: 1, "I'll send the summary after this."),
            ],
            duration: 15,
            processingTime: 2.4
        )
        let markdown = TranscriptSaver.formatTranscriptMarkdown(
            result: result,
            transcriptId: UUID(uuidString: "00000000-0000-0000-0000-00000000A001")!,
            // Keys are channel-qualified, as the pipeline writes them. A
            // suggested (unconfirmed) name must stay generic in the file.
            speakerMappings: [
                "system_0": SpeakerMapping(speakerId: "0", identifiedName: "Sample Colleague", isConfirmedIdentity: true),
                "system_1": SpeakerMapping(speakerId: "1", identifiedName: "Unconfirmed Guess", isConfirmedIdentity: false),
            ],
            date: Self.meetingDate,
            meetingTitle: "Weekly Sync"
        )
        try assertMatchesGolden(markdown, named: "two-person-call")
    }

    func testMicOnlyRoomMeetingMatchesApprovedMarkdown() throws {
        let result = TranscriptionResult(
            micUtterances: [
                utterance(0.0, 4.0, channel: 0, speaker: 0, "Okay, quick notes before the demo."),
                utterance(4.5, 8.0, channel: 0, speaker: 0, "First, the export button moved."),
            ],
            systemUtterances: [],
            duration: 8,
            processingTime: 0.9,
            systemAudioOutcome: .notProvided
        )
        let markdown = TranscriptSaver.formatTranscriptMarkdown(
            result: result,
            transcriptId: UUID(uuidString: "00000000-0000-0000-0000-00000000A002")!,
            date: Self.meetingDate,
            formatOptions: TranscriptFormatOptions(audioSources: [.microphone])
        )
        try assertMatchesGolden(markdown, named: "mic-only-room-meeting")
    }

    func testImportedAudioWithObsidianMetadataMatchesApprovedMarkdown() throws {
        let result = TranscriptionResult(
            micUtterances: [],
            systemUtterances: [
                utterance(0.0, 5.5, channel: 1, speaker: 0, "Welcome back to the show."),
                utterance(6.0, 11.0, channel: 1, speaker: 1, "Glad to be here, it's been a while."),
            ],
            duration: 11,
            processingTime: 1.7,
            microphoneAudioOutcome: .notProvided
        )
        let markdown = TranscriptSaver.formatTranscriptMarkdown(
            result: result,
            transcriptId: UUID(uuidString: "00000000-0000-0000-0000-00000000A003")!,
            date: Self.meetingDate,
            meetingTitle: "Imported Episode",
            formatOptions: TranscriptFormatOptions(
                audioSources: [.systemAudio],
                includeObsidianMetadata: true,
                importedAt: Self.importedDate
            )
        )
        try assertMatchesGolden(markdown, named: "imported-audio-obsidian")
    }

    // MARK: - Helpers

    private func utterance(
        _ start: Double,
        _ end: Double,
        channel: Int,
        speaker: Int,
        _ text: String
    ) -> TranscriptionUtterance {
        TranscriptionUtterance(
            start: start,
            end: end,
            channel: channel,
            speakerId: speaker,
            persistentSpeakerId: nil,
            matchSimilarity: nil,
            transcript: text
        )
    }

    /// Swaps the machine-dependent date strings for placeholders. Longest
    /// strings first so a shorter one never cuts into a longer one.
    private func normalized(_ markdown: String) -> String {
        let replacements = [
            (DateFormattingHelper.formatDisplay(Self.meetingDate), "{{display_date}}"),
            (TranscriptFrontmatter.formatImportedAt(Self.importedDate), "{{imported_at}}"),
            (DateFormattingHelper.formatDayStamp(Self.meetingDate), "{{day}}"),
            (DateFormattingHelper.formatTimeOfDay(Self.meetingDate), "{{time}}"),
        ].sorted { $0.0.count > $1.0.count }
        return replacements.reduce(markdown) { text, pair in
            text.replacingOccurrences(of: pair.0, with: pair.1)
        }
    }

    private func assertMatchesGolden(
        _ markdown: String,
        named name: String,
        file: StaticString = #filePath,
        line: UInt = #line
    ) throws {
        let actual = normalized(markdown)
        let url = Self.goldenDirectory.appendingPathComponent("\(name).md")

        if ProcessInfo.processInfo.environment["TRANSCRIPTED_UPDATE_GOLDENS"] == "1" {
            try FileManager.default.createDirectory(at: Self.goldenDirectory, withIntermediateDirectories: true)
            try actual.write(to: url, atomically: true, encoding: .utf8)
            return
        }

        guard let expected = try? String(contentsOf: url, encoding: .utf8) else {
            XCTFail(
                "No approved copy at Tests/Fixtures/golden-meetings/\(name).md. Create it with: "
                    + "TRANSCRIPTED_UPDATE_GOLDENS=1 swift test --filter MeetingMarkdownGoldenTests",
                file: file,
                line: line
            )
            return
        }
        guard actual != expected else { return }

        let actualLines = actual.components(separatedBy: "\n")
        let expectedLines = expected.components(separatedBy: "\n")
        let firstDifference = zip(actualLines, expectedLines).enumerated().first { $0.element.0 != $0.element.1 }?.offset
            ?? min(actualLines.count, expectedLines.count)
        let expectedLine = firstDifference < expectedLines.count ? expectedLines[firstDifference] : "<end of file>"
        let actualLine = firstDifference < actualLines.count ? actualLines[firstDifference] : "<end of file>"
        XCTFail(
            """
            Saved meeting Markdown changed for "\(name)" at line \(firstDifference + 1).
              approved: \(expectedLine)
              now:      \(actualLine)
            If the change is intended, regenerate and review the diff:
              TRANSCRIPTED_UPDATE_GOLDENS=1 swift test --filter MeetingMarkdownGoldenTests
            """,
            file: file,
            line: line
        )
    }
}
