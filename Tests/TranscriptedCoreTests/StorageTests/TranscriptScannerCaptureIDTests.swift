import XCTest
@testable import TranscriptedCore

/// Pins the capture-id parsing introduced by the markdown-first storage refactor.
/// The scanner must round-trip the `capture_id` / `transcript_id` frontmatter field
/// into `RecordingMetadata.id`, mint a UUID when absent, and cap adversarial values
/// at 256 characters before they reach the stats database.
@available(macOS 14.0, *)
final class TranscriptScannerCaptureIDTests: XCTestCase {

    private var workingDirectory: URL!

    override func setUp() {
        super.setUp()
        workingDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("TranscriptScannerCaptureIDTests-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: workingDirectory, withIntermediateDirectories: true)
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: workingDirectory)
        workingDirectory = nil
        super.tearDown()
    }

    func testParsesCaptureIDFromFrontmatter() throws {
        let captureID = "cap_abc123"
        let url = try writeTranscript(captureIDField: "capture_id", captureID: captureID)

        let parsed = TranscriptScanner.parseTranscriptFile(url)

        XCTAssertEqual(parsed?.0.id, captureID)
    }

    func testParsesLegacyTranscriptIDField() throws {
        let captureID = "legacy_xyz"
        let url = try writeTranscript(captureIDField: "transcript_id", captureID: captureID)

        let parsed = TranscriptScanner.parseTranscriptFile(url)

        XCTAssertEqual(parsed?.0.id, captureID)
    }

    func testFallsBackToFreshUUIDWhenCaptureIDMissing() throws {
        let url = try writeTranscript(captureIDField: nil, captureID: nil)

        let parsed = TranscriptScanner.parseTranscriptFile(url)

        let id = try XCTUnwrap(parsed?.0.id)
        XCTAssertFalse(id.isEmpty)
        XCTAssertNotNil(UUID(uuidString: id), "fallback id should be a valid UUID")
    }

    func testOversizedCaptureIDIsTruncatedTo256Characters() throws {
        let oversizedID = String(repeating: "a", count: 1024)
        let url = try writeTranscript(captureIDField: "capture_id", captureID: oversizedID)

        let parsed = TranscriptScanner.parseTranscriptFile(url)

        XCTAssertEqual(parsed?.0.id.count, 256)
        XCTAssertEqual(parsed?.0.id, String(repeating: "a", count: 256))
    }

    func testCaptureIDPrefersTranscriptIDOverCaptureIDWhenBothPresent() throws {
        let transcriptID = "legacy_first"
        let captureID = "should_not_win"
        let raw = """
        ---
        capture_type: meeting
        title: "Mixed Fields"
        date: 2026-04-22
        time: "13:14:15"
        duration: "00:30"
        transcript_id: \(transcriptID)
        capture_id: \(captureID)
        ---

        ## Transcript

        Hello.
        """
        let url = workingDirectory.appendingPathComponent("mixed.md")
        try raw.write(to: url, atomically: true, encoding: .utf8)

        let parsed = TranscriptScanner.parseTranscriptFile(url)

        XCTAssertEqual(parsed?.0.id, transcriptID, "transcript_id takes precedence (left side of `??`)")
    }

    private func writeTranscript(captureIDField: String?, captureID: String?) throws -> URL {
        var frontmatter = """
        ---
        capture_type: meeting
        title: "Sample"
        date: 2026-04-22
        time: "13:14:15"
        duration: "00:30"
        total_word_count: 3
        """
        if let captureIDField, let captureID {
            frontmatter += "\n\(captureIDField): \(captureID)"
        }
        frontmatter += "\n---\n\n## Transcript\n\nHello world here.\n"

        let url = workingDirectory.appendingPathComponent("sample-\(UUID().uuidString).md")
        try frontmatter.write(to: url, atomically: true, encoding: .utf8)
        return url
    }
}
