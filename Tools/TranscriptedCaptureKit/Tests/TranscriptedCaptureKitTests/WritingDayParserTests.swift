import XCTest
@testable import TranscriptedCaptureKit

/// Parser side of the writing day-file contract (phase 3 format contract,
/// mirrored in docs/capture-format.md once the writer ships). The first entry
/// below is the contract example verbatim; the second covers the cases the
/// contract calls out: a missing `Bundle ID:` line and keys this parser
/// doesn't know (frontmatter and entry metadata), which must be ignored.
final class WritingDayParserTests: XCTestCase {
    static let contractDay = """
    ---
    title: "Writing for September 25, 2026"
    date: 2026-09-25
    capture_type: writing_day
    format_version: 1
    future_header_key: "ignored by readers"
    ---

    # Writing for September 25, 2026

    ## 10:42 AM - Pushing the launch to Thursday so QA

    Entry ID: `writing-20260925-104211-387-4f2a9c1e`
    Captured: 2026-09-25T15:42:11.387Z
    Source app: Slack
    Bundle ID: `com.tinyspeck.slackmacgap`
    Words: 14
    Characters: 71
    Accepted words: 3

    Pushing the launch to Thursday so QA can finish the AirPods pass.

    ## 11:05 AM - Writing Sep 25 at 11:05 AM

    Entry ID: `writing-20260925-160501-002-0b1c2d3e`
    Captured: 2026-09-25T16:05:01.002Z
    Source app: Notes
    Words: 4
    Characters: 21
    Accepted words: 0
    Mood: unknown-future-key

    Sounds ok
    second line

    """

    func testParsesContractExampleFieldForField() throws {
        let url = URL(fileURLWithPath: "/tmp/writing/Writing_2026-09-25.md")
        let parsed = try XCTUnwrap(CaptureMarkdownParser.parseWritingDay(from: Self.contractDay, markdownURL: url))

        XCTAssertEqual(parsed.captureType, "writing_day")
        XCTAssertEqual(parsed.date, "2026-09-25")
        XCTAssertEqual(parsed.formatVersion, 1)
        XCTAssertEqual(parsed.markdownFilename, "Writing_2026-09-25.md")
        XCTAssertEqual(parsed.entryCount, 2)
        // Declared counts are taken as written, not recomputed from the text:
        // the contract example's 14/71 are the writer's numbers.
        XCTAssertEqual(parsed.wordCount, 18)
        XCTAssertEqual(parsed.acceptedWordCount, 3)

        let first = parsed.entries[0]
        XCTAssertEqual(first.id, "writing-20260925-104211-387-4f2a9c1e")
        XCTAssertEqual(first.createdAt, "2026-09-25T15:42:11.387Z")
        XCTAssertEqual(first.title, "Pushing the launch to Thursday so QA")
        XCTAssertEqual(first.sourceAppName, "Slack")
        XCTAssertEqual(first.sourceAppBundleId, "com.tinyspeck.slackmacgap")
        XCTAssertEqual(first.wordCount, 14)
        XCTAssertEqual(first.characterCount, 71)
        XCTAssertEqual(first.acceptedWordCount, 3)
        XCTAssertEqual(
            Array(first.text.utf8),
            Array("Pushing the launch to Thursday so QA can finish the AirPods pass.".utf8),
            "entry text must round-trip byte for byte"
        )
    }

    func testMissingBundleIdAndUnknownKeysAreTolerated() throws {
        let url = URL(fileURLWithPath: "/tmp/writing/Writing_2026-09-25.md")
        let parsed = try XCTUnwrap(CaptureMarkdownParser.parseWritingDay(from: Self.contractDay, markdownURL: url))

        let second = parsed.entries[1]
        XCTAssertEqual(second.id, "writing-20260925-160501-002-0b1c2d3e")
        XCTAssertEqual(second.title, "Writing Sep 25 at 11:05 AM")
        XCTAssertEqual(second.sourceAppName, "Notes")
        XCTAssertNil(second.sourceAppBundleId, "an omitted Bundle ID line means unknown, not empty")
        XCTAssertEqual(second.wordCount, 4)
        XCTAssertEqual(second.characterCount, 21)
        XCTAssertEqual(second.acceptedWordCount, 0)
        XCTAssertEqual(
            Array(second.text.utf8),
            Array("Sounds ok\nsecond line".utf8),
            "an unknown metadata line must not leak into the text, and inner newlines survive"
        )
    }

    func testEntriesSortAscendingAndDateFallsBackToFilename() throws {
        let markdown = """
        ---
        capture_type: writing_day
        ---

        ## 4:00 PM - Later

        Entry ID: `writing-b`
        Captured: 2026-09-26T21:00:00.000Z
        Source app: Mail

        Later text

        ## 9:00 AM - Earlier

        Entry ID: `writing-a`
        Captured: 2026-09-26T14:00:00.000Z
        Source app: Mail

        Earlier text here
        """
        let url = URL(fileURLWithPath: "/tmp/Writing_2026-09-26.md")
        let parsed = try XCTUnwrap(CaptureMarkdownParser.parseWritingDay(from: markdown, markdownURL: url))

        XCTAssertEqual(parsed.date, "2026-09-26")
        XCTAssertNil(parsed.formatVersion, "absent format_version parses as version 1 semantics")
        XCTAssertEqual(parsed.entries.map(\.id), ["writing-a", "writing-b"])
        XCTAssertEqual(parsed.entries.map(\.wordCount), [3, 2], "missing Words line falls back to counting the text")
        XCTAssertEqual(parsed.entries.map(\.acceptedWordCount), [0, 0])
    }

    func testWritingParserDoesNotConsumeDictationDeliveryLine() throws {
        // A Delivery line is dictation-only; in a writing file it is an unknown
        // key and is dropped like any other.
        let markdown = """
        ---
        capture_type: writing_day
        date: 2026-09-25
        ---

        ## 10:00 AM - Hi there

        Entry ID: `writing-x`
        Captured: 2026-09-25T15:00:00.000Z
        Source app: Slack
        Delivery: pasted
        Words: 2

        Hi there
        """
        let url = URL(fileURLWithPath: "/tmp/Writing_2026-09-25.md")
        let parsed = try XCTUnwrap(CaptureMarkdownParser.parseWritingDay(from: markdown, markdownURL: url))
        XCTAssertEqual(parsed.entries.first?.text, "Hi there")
    }

    func testParseWritingDayWithoutFrontmatterReturnsNil() {
        let url = URL(fileURLWithPath: "/tmp/Writing_2026-09-25.md")
        XCTAssertNil(CaptureMarkdownParser.parseWritingDay(from: "# No frontmatter", markdownURL: url))
    }

    func testDictationParsingIgnoresAcceptedWordsLine() throws {
        // The shared day-file section parser must keep dictation behavior
        // unchanged: `Accepted words:` is not a dictation key.
        let markdown = """
        ---
        capture_type: dictation_day
        date: 2026-09-25
        ---

        ## 10:00 AM - Note

        Entry ID: `dictation-1`
        Captured: 2026-09-25T15:00:00.000Z
        Source app: Slack
        Delivery: pasted
        Accepted words: 3
        Words: 2

        Note text
        """
        let url = URL(fileURLWithPath: "/tmp/Dictations_2026-09-25.md")
        let parsed = try XCTUnwrap(CaptureMarkdownParser.parseDictationDay(from: markdown, markdownURL: url))
        XCTAssertEqual(parsed.entries.first?.delivery, "pasted")
        XCTAssertEqual(parsed.entries.first?.wordCount, 2)
        XCTAssertEqual(parsed.entries.first?.text, "Note text")
    }

    func testCaptureKindRecognizesWritingByPrefixAndCaptureType() throws {
        let tempDir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let byPrefix = tempDir.appendingPathComponent("Writing_2026-09-25.md")
        try Self.contractDay.write(to: byPrefix, atomically: true, encoding: .utf8)
        XCTAssertEqual(CaptureMarkdown.captureKind(of: byPrefix), .writingDay)
        XCTAssertTrue(CaptureMarkdown.looksLikeCaptureMarkdown(byPrefix))

        let byCaptureType = tempDir.appendingPathComponent("renamed-copy.md")
        try Self.contractDay.write(to: byCaptureType, atomically: true, encoding: .utf8)
        XCTAssertEqual(
            CaptureMarkdown.captureKind(of: byCaptureType),
            .writingDay,
            "capture_type: writing_day must win over the frontmatter-means-meeting default"
        )

        let dictation = tempDir.appendingPathComponent("Dictations_2026-09-25.md")
        try "anything".write(to: dictation, atomically: true, encoding: .utf8)
        XCTAssertEqual(CaptureMarkdown.captureKind(of: dictation), .dictationDay)

        let meeting = tempDir.appendingPathComponent("Call_2026-09-25_10-00-00.md")
        try "---\ncapture_type: meeting\ndate: 2026-09-25\n---\n\nbody".write(to: meeting, atomically: true, encoding: .utf8)
        XCTAssertEqual(CaptureMarkdown.captureKind(of: meeting), .meeting)

        let notes = tempDir.appendingPathComponent("README.md")
        try "# Notes".write(to: notes, atomically: true, encoding: .utf8)
        XCTAssertNil(CaptureMarkdown.captureKind(of: notes))
    }
}
