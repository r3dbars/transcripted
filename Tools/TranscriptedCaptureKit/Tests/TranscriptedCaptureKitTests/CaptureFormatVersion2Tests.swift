import XCTest
@testable import TranscriptedCaptureKit

/// `format_version: 2` meetings: `[MM:SS] **Speaker:** text` rows whose
/// channel comes from the frontmatter, `recorded_at`, the hidden
/// `.meta/<capture_id>.json` sidecar, and the on-device `## Summary`.
final class CaptureFormatVersion2Tests: XCTestCase {
    private let captureID = "5E9A0000-0000-0000-0000-0000000000E3"

    private func v2Meeting(dateLines: String = "date: 2026-11-26\ntime: 19:58:41", extra: String = "", body: String? = nil) -> String {
        """
        ---
        title: "Quick notes"
        capture_id: "\(captureID)"
        capture_type: meeting
        format_version: 2
        transcript_style: styled
        recorded_at: 2026-11-26T19:58:41-06:00
        \(dateLines)
        duration: "8:34"
        total_word_count: 18
        \(extra)speakers:
          - id: "0"
            channel: mic
            name: "Dana"
            confidence: high
            source: db
          - id: "1"
            channel: system
            db_id: "22222222-2222-2222-2222-222222222222"
            name: "Speaker 1"
            confidence: unknown
            source: db_pending
          - id: "2"
            channel: system
            name: "Dana"
            confidence: unknown
            source: db_pending
        ---

        # Quick notes

        Recorded Nov 26, 2026 at 7:58 PM  •  8 min, 34 sec  •  18 words  •  4 turns

        ## Summary

        Two bids were compared. The current vendor stays.

        ## Transcript

        \(body ?? """
        [00:00] **You:** Thanks for making time today.

        [00:04] **Speaker 1:** Happy to help.

        [00:09] **Mic/Dana:** Dana in the room.

        [00:12] **Dana:** And Dana on the call.
        """)

        """
    }

    func testParsesV2RowsWithFrontmatterChannels() throws {
        let parsed = try XCTUnwrap(CaptureMarkdownParser.parseMeeting(from: v2Meeting()))

        XCTAssertEqual(parsed.formatVersion, 2)
        XCTAssertEqual(parsed.transcriptStyle, "styled")
        XCTAssertEqual(parsed.datetime, "2026-11-26T19:58:41")
        XCTAssertEqual(parsed.utterances.map(\.start), [0, 4, 9, 12])
        XCTAssertEqual(parsed.utterances.map(\.text), [
            "Thanks for making time today.",
            "Happy to help.",
            "Dana in the room.",
            "And Dana on the call.",
        ], "the summary section is not a transcript row")
        let names = Dictionary(uniqueKeysWithValues: parsed.speakers.map { ($0.id, $0.name) })
        XCTAssertEqual(parsed.utterances.map(\.speakerId), [
            parsed.utterances[0].speakerId, "system_1", parsed.utterances[2].speakerId, parsed.utterances[3].speakerId,
        ])
        XCTAssertTrue(parsed.utterances[0].speakerId.hasPrefix("mic_"), "a bare You is the mic")
        XCTAssertTrue(parsed.utterances[2].speakerId.hasPrefix("mic_"), "Mic/Dana spells out the mic")
        XCTAssertTrue(parsed.utterances[3].speakerId.hasPrefix("system_"), "a bare name on both channels reads as the call")
        XCTAssertEqual(names["system_1"], "Speaker 1")
        XCTAssertEqual(
            parsed.speakers.first { $0.id == "system_1" }?.persistentSpeakerId,
            "22222222-2222-2222-2222-222222222222"
        )
    }

    func testV1BodiesStillParse() throws {
        let v1Styled = v2Meeting(body: """
        **00:00**  [Mic/You]
        Thanks for making time today.

        **00:04**  [System/Speaker 1]
        Happy to help.
        """)
        let parsed = try XCTUnwrap(CaptureMarkdownParser.parseMeeting(from: v1Styled))
        XCTAssertEqual(parsed.utterances.map(\.text), ["Thanks for making time today.", "Happy to help."])
        XCTAssertEqual(parsed.utterances.last?.speakerId, "system_1")
    }

    func testRecordedAtFillsInMissingDateAndTime() throws {
        let parsed = try XCTUnwrap(CaptureMarkdownParser.parseMeeting(from: v2Meeting(dateLines: "")))
        XCTAssertEqual(parsed.datetime, "2026-11-26T19:58:41")
    }

    func testSidecarFillsPipelineKeysTheMarkdownDropped() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("CaptureFormatVersion2Tests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(
            at: directory.appendingPathComponent(".meta"), withIntermediateDirectories: true
        )
        defer { try? FileManager.default.removeItem(at: directory) }
        let markdownURL = directory.appendingPathComponent("2026-11-26 Quick notes.md")
        let content = v2Meeting()
        try content.write(to: markdownURL, atomically: true, encoding: .utf8)
        try """
        {"schema_version": 1, "capture_id": "\(captureID)", "frontmatter": {
          "transcription_engine": "parakeet_local",
          "diarization_engine": "nemotron_offline",
          "sources": ["mic", "system_audio"]
        }}
        """.write(
            to: directory.appendingPathComponent(".meta/\(captureID).json"), atomically: true, encoding: .utf8
        )

        let sidecar = CaptureMeetingMetadataSidecar.values(forMeetingAt: markdownURL, content: content)
        XCTAssertEqual(sidecar["sources"], "mic, system_audio")
        let parsed = try XCTUnwrap(CaptureMarkdownParser.parseMeeting(from: content, metadataSidecar: sidecar))
        XCTAssertEqual(parsed.sttEngine, "parakeet_local")
        XCTAssertEqual(parsed.diarizationEngine, "nemotron_offline")
        XCTAssertEqual(CaptureMarkdownParser.parseMeeting(from: content)?.sttEngine, "unknown")
    }

    func testSummaryParserReturnsOnDeviceSummary() throws {
        let labeled = v2Meeting(extra: """
        ai_title: "Vendor contract renewal"
        ai_title_replaces: "Quick notes"
        ai_summary_line: "The renewal goes ahead."
        ai_summary: "Two bids were compared. The current vendor stays."
        ai_summary_version: "1"

        """)
        let summary = try XCTUnwrap(CaptureSummaryParser.parse(from: labeled))
        XCTAssertEqual(summary.title, "Vendor contract renewal")
        XCTAssertEqual(summary.summary, "Two bids were compared. The current vendor stays.")

        // The body section alone (keys stripped by hand) still counts.
        let bodyOnly = try XCTUnwrap(CaptureSummaryParser.parse(from: v2Meeting()))
        XCTAssertNil(bodyOnly.title)
        XCTAssertEqual(bodyOnly.summary, "Two bids were compared. The current vendor stays.")

        // A title the person set wins over the model's.
        let renamed = labeled.replacingOccurrences(of: "title: \"Quick notes\"", with: "title: \"Budget review\"")
        XCTAssertNil(try XCTUnwrap(CaptureSummaryParser.parse(from: renamed)).title)
    }

    func testLegacyQuickSummaryStillParses() throws {
        let legacy = v2Meeting(extra: """
        auto_summary_version: "1"
        auto_summary_decisions: "Ship on Friday"

        """)
        let summary = try XCTUnwrap(CaptureSummaryParser.parse(from: legacy))
        XCTAssertEqual(summary.decisions, ["Ship on Friday"])
        XCTAssertEqual(summary.summary, "Two bids were compared. The current vendor stays.")
    }
}
