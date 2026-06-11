import XCTest
@testable import TranscriptedCaptureKit

final class CaptureMarkdownParserTests: XCTestCase {
    func testParseMeetingLegacyTranscriptAssignsSpeakerIdsAndMetadata() throws {
        let markdown = """
        ---
        capture_type: meeting
        date: 2026-04-18
        time: 09:15:00
        duration: "30:00"
        dropped_segments: 2
        transcription_engine: parakeet_local
        diarization_engine: pyannote_offline
        speakers:
          - id: "0"
            db_id: "80FB272B-6061-4FC4-8408-3F7A974C59DB"
            name: "Jenny Wen"
            confidence: high
            source: db_scan
        ---

        # Meeting Fixture

        ## Full Transcript

        [00:00] [Mic/You] Good morning everyone

        [00:05] [System/Jenny Wen] Let's discuss the product roadmap
        """

        let parsed = try XCTUnwrap(CaptureMarkdownParser.parseMeeting(from: markdown))

        XCTAssertEqual(parsed.datetime, "2026-04-18T09:15:00")
        XCTAssertEqual(parsed.durationSeconds, 1800)
        XCTAssertEqual(parsed.droppedSegments, 2)
        XCTAssertEqual(parsed.sttEngine, "parakeet_local")
        XCTAssertEqual(parsed.diarizationEngine, "pyannote_offline")
        XCTAssertEqual(parsed.utterances.count, 2)
        XCTAssertEqual(parsed.utterances.map(\.speakerId), ["mic_0", "system_0"])

        let system = try XCTUnwrap(parsed.speakers.first(where: { $0.id == "system_0" }))
        XCTAssertEqual(system.name, "Jenny Wen")
        XCTAssertEqual(system.persistentSpeakerId, "80FB272B-6061-4FC4-8408-3F7A974C59DB")
        XCTAssertEqual(system.confidence, "high")
        XCTAssertEqual(system.wordCount, 5)
    }

    func testParseMeetingStyledTranscriptSection() throws {
        let markdown = """
        ---
        capture_type: meeting
        date: 2026-04-18
        time: 09:15:00
        duration: "0:18"
        ---

        ## Transcript

        **00:03 [Mic/You]**
        Styled entry text here.

        **00:07 [System/Alex]**
        Reply from the other side.
        """

        let parsed = try XCTUnwrap(CaptureMarkdownParser.parseMeeting(from: markdown))

        XCTAssertEqual(parsed.utterances.count, 2)
        XCTAssertEqual(parsed.utterances.first?.text, "Styled entry text here.")
        XCTAssertEqual(parsed.utterances.first?.start, 3)
        XCTAssertEqual(parsed.utterances.first?.end, 7)
    }

    func testParseMeetingSkipsMalformedLegacyRows() throws {
        let markdown = """
        ---
        capture_type: meeting
        date: 2026-04-18
        time: 09:15:00
        duration: "0:18"
        ---

        ## Full Transcript

        [00:00]
        [00:01]x
        [00:02] [
        [00:03] [Mic/You] Still works.
        """

        let parsed = try XCTUnwrap(CaptureMarkdownParser.parseMeeting(from: markdown))

        XCTAssertEqual(parsed.utterances.count, 1)
        XCTAssertEqual(parsed.utterances.first?.text, "Still works.")
    }

    func testMalformedDurationFallsBackToZero() throws {
        for duration in ["1:bad", "-1:02"] {
            let markdown = """
            ---
            date: 2026-04-18
            time: 09:15:00
            duration: "\(duration)"
            ---

            ## Full Transcript

            [00:03] [Mic/You] Still works.
            """
            let parsed = CaptureMarkdownParser.parseMeeting(from: markdown)
            XCTAssertEqual(parsed?.durationSeconds, 0)
        }
    }

    func testParseMeetingDuplicateSpeakerNamesDoesNotCrash() throws {
        let markdown = """
        ---
        date: 2026-04-18
        time: 09:15:00
        speakers:
          - id: "0"
            db_id: "AAA"
            name: "Alex"
          - id: "1"
            db_id: "BBB"
            name: "Alex"
        ---

        ## Full Transcript

        [00:00] [System/Alex] First speaker with the shared display name.

        [00:04] [System/Alex] Second speaker with the shared display name.
        """

        let parsed = try XCTUnwrap(CaptureMarkdownParser.parseMeeting(from: markdown))
        XCTAssertEqual(parsed.utterances.count, 2)
    }

    func testParseMeetingMalformedContentReturnsNil() {
        XCTAssertNil(CaptureMarkdownParser.parseMeeting(from: "not markdown at all"))
    }

    func testParseDictationDayEntriesSortedByCreatedAt() throws {
        let markdown = """
        ---
        title: "Dictations for 2026-04-07"
        date: 2026-04-07
        capture_type: dictation_day
        ---

        # Dictations for 2026-04-07

        ## 6:30 PM - Evening note

        Entry ID: `dictation-2`
        Captured: 2026-04-07T18:30:00Z
        Source app: Mail
        Delivery: pasted
        Words: 7

        Remember to send the recap before dinner

        ## 9:15 AM - Morning note

        Entry ID: `dictation-1`
        Captured: 2026-04-07T09:15:00Z
        Source app: Slack
        Bundle ID: `com.example.slack`
        Delivery: copied
        Words: 7

        Ship the follow-up note to product today
        """

        let url = URL(fileURLWithPath: "/tmp/Dictations_2026-04-07.md")
        let parsed = try XCTUnwrap(CaptureMarkdownParser.parseDictationDay(from: markdown, markdownURL: url))

        XCTAssertEqual(parsed.captureType, "dictation_day")
        XCTAssertEqual(parsed.date, "2026-04-07")
        XCTAssertEqual(parsed.markdownFilename, "Dictations_2026-04-07.md")
        XCTAssertEqual(parsed.entryCount, 2)
        XCTAssertEqual(parsed.entries.map(\.id), ["dictation-1", "dictation-2"])
        XCTAssertEqual(parsed.entries.first?.title, "Morning note")
        XCTAssertEqual(parsed.entries.first?.sourceAppBundleId, "com.example.slack")
        XCTAssertEqual(parsed.wordCount, 14)
    }

    func testParseDictationDayWithoutFrontmatterReturnsNil() {
        let url = URL(fileURLWithPath: "/tmp/Dictations_2026-04-07.md")
        XCTAssertNil(CaptureMarkdownParser.parseDictationDay(from: "# No frontmatter", markdownURL: url))
    }

    func testParseDictationDayDateFallsBackToFilename() throws {
        let markdown = """
        ---
        capture_type: dictation_day
        ---

        ## 9:15 AM - Note

        Entry ID: `dictation-1`
        Captured: 2026-04-08T09:15:00Z

        Some text
        """
        let url = URL(fileURLWithPath: "/tmp/Dictations_2026-04-08.md")
        let parsed = try XCTUnwrap(CaptureMarkdownParser.parseDictationDay(from: markdown, markdownURL: url))
        XCTAssertEqual(parsed.date, "2026-04-08")
    }

    func testExtractTitleTrimsQuotes() {
        let markdown = """
        ---
        title: "Product review"
        date: 2026-04-18
        ---

        body
        """
        XCTAssertEqual(CaptureMarkdown.extractTitle(from: markdown), "Product review")
        XCTAssertNil(CaptureMarkdown.extractTitle(from: "no frontmatter"))
    }

    func testLooksLikeCaptureMarkdown() throws {
        let tempDir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let dictation = tempDir.appendingPathComponent("Dictations_2026-04-07.md")
        try "anything".write(to: dictation, atomically: true, encoding: .utf8)
        XCTAssertTrue(CaptureMarkdown.looksLikeCaptureMarkdown(dictation))

        let meeting = tempDir.appendingPathComponent("Call_test.md")
        try "---\ndate: 2026-04-18\n---\n\nbody".write(to: meeting, atomically: true, encoding: .utf8)
        XCTAssertTrue(CaptureMarkdown.looksLikeCaptureMarkdown(meeting))

        let notes = tempDir.appendingPathComponent("CLAUDE.md")
        try "# Notes".write(to: notes, atomically: true, encoding: .utf8)
        XCTAssertFalse(CaptureMarkdown.looksLikeCaptureMarkdown(notes))

        XCTAssertTrue(CaptureMarkdown.directoryHasCaptureMarkdownFiles(tempDir))
    }
}
