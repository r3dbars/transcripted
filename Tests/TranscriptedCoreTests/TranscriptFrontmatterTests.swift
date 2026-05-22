import XCTest
@testable import TranscriptedCore

final class TranscriptFrontmatterTests: XCTestCase {
    func testParsesFlatValuesAndBody() throws {
        let raw = """
        ---
        capture_type: meeting
        title: "Product Review: Follow-up"
        duration: "1:02:03"
        total_word_count: 42
        speakers:
          - id: "system_0"
            name: "Alex"
        ---

        ## Transcript

        Hello.
        """

        let document = try XCTUnwrap(TranscriptFrontmatter.document(in: raw))

        XCTAssertEqual(document.values["capture_type"], "meeting")
        XCTAssertEqual(document.values["title"], "Product Review: Follow-up")
        XCTAssertEqual(document.values["duration"], "1:02:03")
        XCTAssertEqual(document.values["total_word_count"], "42")
        XCTAssertNil(document.values["name"])
        XCTAssertEqual(document.body.trimmingCharacters(in: .whitespacesAndNewlines), "## Transcript\n\nHello.")
        XCTAssertTrue(document.lines.contains("speakers:"))
    }

    func testParsesDurationShapes() {
        XCTAssertEqual(TranscriptFrontmatter.durationSeconds(from: "45"), 45)
        XCTAssertEqual(TranscriptFrontmatter.durationSeconds(from: "12:34"), 754)
        XCTAssertEqual(TranscriptFrontmatter.durationSeconds(from: "1:02:03"), 3723)
        XCTAssertNil(TranscriptFrontmatter.durationSeconds(from: "not a duration"))
        XCTAssertNil(TranscriptFrontmatter.durationSeconds(from: "1:bad"))
        XCTAssertNil(TranscriptFrontmatter.durationSeconds(from: "1:02:bad"))
        XCTAssertNil(TranscriptFrontmatter.durationSeconds(from: "1:"))
        XCTAssertNil(TranscriptFrontmatter.durationSeconds(from: "-1:02"))
    }

    func testParsesRecordedAt() throws {
        let date = try XCTUnwrap(
            TranscriptFrontmatter.recordedAt(
                values: [
                    "date": "2026-04-22",
                    "time": "13:14:15"
                ]
            )
        )

        let components = Calendar(identifier: .gregorian)
            .dateComponents(in: TimeZone.current, from: date)
        XCTAssertEqual(components.year, 2026)
        XCTAssertEqual(components.month, 4)
        XCTAssertEqual(components.day, 22)
        XCTAssertEqual(components.hour, 13)
        XCTAssertEqual(components.minute, 14)
        XCTAssertEqual(components.second, 15)
    }

    func testReadValuesUsesBoundedPrefix() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("TranscriptFrontmatterTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        let url = directory.appendingPathComponent("meeting.md")
        let raw = """
        ---
        title: "Large Meeting"
        duration: "42:17"
        ---

        \(String(repeating: "body\n", count: 1_000))
        """
        try raw.write(to: url, atomically: true, encoding: .utf8)

        let values = try XCTUnwrap(try TranscriptFrontmatter.readValues(from: url))

        XCTAssertEqual(values["title"], "Large Meeting")
        XCTAssertEqual(values["duration"], "42:17")
    }

    func testReadValuesContinuesUntilLargeFrontmatterCloses() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("TranscriptFrontmatterTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        let url = directory.appendingPathComponent("long-meeting.md")
        let gapEvents = (0..<3_000)
            .map { "  - \"gap \($0) \(String(repeating: "x", count: 24))\"" }
            .joined(separator: "\n")
        let raw = """
        ---
        capture_type: meeting
        title: "Long Meeting"
        duration: "120:00"
        gap_events:
        \(gapEvents)
        ---

        ## Full Transcript

        Hello.
        """
        try raw.write(to: url, atomically: true, encoding: .utf8)

        let values = try XCTUnwrap(try TranscriptFrontmatter.readValues(from: url))

        XCTAssertEqual(values["capture_type"], "meeting")
        XCTAssertEqual(values["title"], "Long Meeting")
        XCTAssertEqual(values["duration"], "120:00")
    }
}
