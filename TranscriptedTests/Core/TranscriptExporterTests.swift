import XCTest
@testable import Transcripted

@available(macOS 14.0, *)
final class TranscriptExporterTests: XCTestCase {

    // MARK: - Test Data

    private func makeSummary(title: String = "Test Meeting", duration: String = "5:30", speakerCount: Int = 2) -> TranscriptSummary {
        TranscriptSummary(
            url: URL(fileURLWithPath: "/tmp/test.md"),
            title: title,
            date: Date(timeIntervalSince1970: 1711200000), // 2024-03-23
            duration: duration,
            speakerCount: speakerCount,
            speakerNames: ["Alice", "Bob"],
            timeOfDay: "14:30:00",
            speakers: []
        )
    }

    private func makeLines() -> [TranscriptLine] {
        [
            TranscriptLine(timestamp: "00:00", speaker: "Mic/You", text: "Hello everyone"),
            TranscriptLine(timestamp: "00:05", speaker: "System/Speaker 0", text: "Hi there"),
            TranscriptLine(timestamp: "00:10", speaker: "Mic/You", text: "Let's begin"),
        ]
    }

    // MARK: - Markdown Content

    func testMarkdownContentContainsTitle() {
        let content = TranscriptExporter.markdownContent(from: makeLines(), summary: makeSummary())
        XCTAssertTrue(content.contains("# Test Meeting"))
    }

    func testMarkdownContentContainsDuration() {
        let content = TranscriptExporter.markdownContent(from: makeLines(), summary: makeSummary())
        XCTAssertTrue(content.contains("5:30"))
    }

    func testMarkdownContentContainsSpeakerCount() {
        let content = TranscriptExporter.markdownContent(from: makeLines(), summary: makeSummary())
        XCTAssertTrue(content.contains("2"))
    }

    func testMarkdownContentContainsUtterances() {
        let content = TranscriptExporter.markdownContent(from: makeLines(), summary: makeSummary())
        XCTAssertTrue(content.contains("Hello everyone"))
        XCTAssertTrue(content.contains("Hi there"))
        XCTAssertTrue(content.contains("Let's begin"))
    }

    func testMarkdownContentFormatsTimestamps() {
        let content = TranscriptExporter.markdownContent(from: makeLines(), summary: makeSummary())
        XCTAssertTrue(content.contains("[00:00]"))
        XCTAssertTrue(content.contains("[00:05]"))
    }

    func testMarkdownContentStripsSpeakerPrefix() {
        let content = TranscriptExporter.markdownContent(from: makeLines(), summary: makeSummary())
        // "Mic/You" should become "You"
        XCTAssertTrue(content.contains("You"))
        // "System/Speaker 0" should become "Speaker 0"
        XCTAssertTrue(content.contains("Speaker 0"))
        // Full prefixed versions should NOT appear
        XCTAssertFalse(content.contains("Mic/You"))
        XCTAssertFalse(content.contains("System/Speaker"))
    }

    func testMarkdownContentContainsFooter() {
        let content = TranscriptExporter.markdownContent(from: makeLines(), summary: makeSummary())
        XCTAssertTrue(content.contains("Exported from Transcripted"))
    }

    // MARK: - Plain Text Content

    func testPlainTextContentContainsTitle() {
        let content = TranscriptExporter.plainTextContent(from: makeLines(), summary: makeSummary())
        XCTAssertTrue(content.contains("Test Meeting"))
    }

    func testPlainTextContentContainsDuration() {
        let content = TranscriptExporter.plainTextContent(from: makeLines(), summary: makeSummary())
        XCTAssertTrue(content.contains("5:30"))
    }

    func testPlainTextContentContainsUtterances() {
        let content = TranscriptExporter.plainTextContent(from: makeLines(), summary: makeSummary())
        XCTAssertTrue(content.contains("Hello everyone"))
        XCTAssertTrue(content.contains("Hi there"))
    }

    func testPlainTextContentHasNoMarkdown() {
        let content = TranscriptExporter.plainTextContent(from: makeLines(), summary: makeSummary())
        XCTAssertFalse(content.contains("**"))
        XCTAssertFalse(content.contains("# "))
    }

    func testPlainTextContentStripsSpeakerPrefix() {
        let content = TranscriptExporter.plainTextContent(from: makeLines(), summary: makeSummary())
        XCTAssertTrue(content.contains("You:"))
        XCTAssertFalse(content.contains("Mic/You"))
    }

    // MARK: - Default Filename

    func testDefaultFilenameMarkdown() {
        let filename = TranscriptExporter.defaultFilename(for: makeSummary(), format: .markdown)
        XCTAssertTrue(filename.hasSuffix(".md"))
        XCTAssertTrue(filename.contains("Test Meeting"))
    }

    func testDefaultFilenamePlainText() {
        let filename = TranscriptExporter.defaultFilename(for: makeSummary(), format: .plainText)
        XCTAssertTrue(filename.hasSuffix(".txt"))
    }

    func testDefaultFilenameDatePrefix() {
        let filename = TranscriptExporter.defaultFilename(for: makeSummary(), format: .markdown)
        // Should start with date in yyyy-MM-dd format
        XCTAssertTrue(filename.hasPrefix("2024-03-23"))
    }

    func testDefaultFilenameTruncatesLongTitle() {
        let longTitle = String(repeating: "A", count: 50)
        let filename = TranscriptExporter.defaultFilename(for: makeSummary(title: longTitle), format: .markdown)
        // Title should be truncated to ~30 chars
        XCTAssertLessThanOrEqual(filename.count, 50) // date(10) + space(1) + title(30) + .md(3) + margin
    }

    func testDefaultFilenameSanitizesUnsafeChars() {
        let filename = TranscriptExporter.defaultFilename(for: makeSummary(title: "Team/Meeting: Update"), format: .markdown)
        XCTAssertFalse(filename.contains("/"))
        XCTAssertFalse(filename.contains(":"))
    }

    // MARK: - Empty Lines

    func testMarkdownContentWithEmptyLines() {
        let content = TranscriptExporter.markdownContent(from: [], summary: makeSummary())
        // Should still produce valid markdown with header
        XCTAssertTrue(content.contains("# Test Meeting"))
        XCTAssertTrue(content.contains("Exported from Transcripted"))
    }

    func testPlainTextContentWithEmptyLines() {
        let content = TranscriptExporter.plainTextContent(from: [], summary: makeSummary())
        XCTAssertTrue(content.contains("Test Meeting"))
    }
}
