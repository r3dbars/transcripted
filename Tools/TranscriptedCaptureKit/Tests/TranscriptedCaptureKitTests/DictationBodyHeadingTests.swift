import Foundation
import XCTest
@testable import TranscriptedCaptureKit

final class DictationBodyHeadingTests: XCTestCase {
    func testMarkdownHeadingsInsideDictationStayInTheSameEntry() throws {
        let text = "First paragraph.\n\n## Project notes\nKeep this line.\n### Detail\n\n## Next steps\nLast paragraph."
        let content = "---\ncapture_type: dictation_day\ndate: 2026-11-09\n---\n\n"
            + section(id: "first", time: "9:00 AM", text: text)
            + "\n\n" + section(id: "second", time: "12:05 PM", text: "Second take.")
        let parsed = try XCTUnwrap(CaptureMarkdownParser.parseDictationDay(
            from: content, markdownURL: URL(fileURLWithPath: "/fixtures/Dictations_2026-11-09.md")
        ))
        XCTAssertEqual(parsed.entries.map(\.id), ["first", "second"])
        XCTAssertEqual(parsed.entries.map(\.text), [text, "Second take."])
    }

    func testLegacyTimestampMetadataAndLiteralEscapesRemainReadable() throws {
        let text = "## Heading\n\\## Literal backslash\nPreserve the text."
        let content = ("---\ncapture_type: dictation_day\ndate: 2026-11-09\n---\n\n"
            + section(id: "legacy", time: "1:45 PM", text: text))
            .replacingOccurrences(of: "Captured:", with: "Timestamp:")
        let parsed = try XCTUnwrap(CaptureMarkdownParser.parseDictationDay(
            from: content, markdownURL: URL(fileURLWithPath: "/fixtures/Dictations_2026-11-09.md")
        ))
        XCTAssertEqual(parsed.entries.count, 1)
        XCTAssertEqual(parsed.entries.first?.text, text)
        XCTAssertEqual(parsed.entries.first?.createdAt, "2026-11-09T15:00:00Z")
    }

    private func section(id: String, time: String, text: String) -> String {
        """
        ## \(time) - Fixture

        Entry ID: `\(id)`
        Captured: 2026-11-09T15:00:00Z
        Words: 2

        \(text)
        """
    }
}
