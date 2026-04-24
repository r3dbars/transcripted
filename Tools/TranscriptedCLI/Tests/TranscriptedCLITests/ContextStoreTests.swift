import XCTest
@testable import transcripted_cli

final class ContextStoreTests: XCTestCase {
    func testRecentMeetingUsesFirstUtteranceAsPreview() throws {
        let root = makeTempDir()
        defer { try? FileManager.default.removeItem(at: root) }

        let meetingsDir = root.appendingPathComponent("meetings", isDirectory: true)
        let dictationsDir = root.appendingPathComponent("dictations", isDirectory: true)
        try FileManager.default.createDirectory(at: meetingsDir, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: dictationsDir, withIntermediateDirectories: true)

        let meeting = """
        ---
        capture_type: meeting
        date: 2026-04-16
        time: 09:15:00
        duration: "0:18"
        ---

        # Product review

        ## Full Transcript

        [00:03] [Mic/You] We should test the onboarding changes before touching pricing.

        [00:08] [System/Speaker 2] Agreed.
        """
        try meeting.write(
            to: meetingsDir.appendingPathComponent("Product review.md"),
            atomically: true,
            encoding: .utf8
        )

        let items = CLIContextStore.recent(
            in: CLIContextDirectories(meetingsDir: meetingsDir, dictationsDir: dictationsDir),
            kind: .meeting,
            count: 5,
            dateFrom: nil,
            dateTo: nil
        )

        XCTAssertEqual(items.count, 1)
        XCTAssertEqual(items.first?.preview, "We should test the onboarding changes before touching pricing.")
    }

    func testRecentMeetingWithNoTranscriptUsesExplicitPreview() throws {
        let root = makeTempDir()
        defer { try? FileManager.default.removeItem(at: root) }

        let meetingsDir = root.appendingPathComponent("meetings", isDirectory: true)
        let dictationsDir = root.appendingPathComponent("dictations", isDirectory: true)
        try FileManager.default.createDirectory(at: meetingsDir, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: dictationsDir, withIntermediateDirectories: true)

        let meeting = """
        ---
        capture_type: meeting
        date: 2026-04-16
        time: 09:15:00
        duration: "0:02"
        total_word_count: 0
        ---

        # Quick notes

        ## Transcript

        _No transcript captured._
        """
        try meeting.write(
            to: meetingsDir.appendingPathComponent("Quick notes.md"),
            atomically: true,
            encoding: .utf8
        )

        let items = CLIContextStore.recent(
            in: CLIContextDirectories(meetingsDir: meetingsDir, dictationsDir: dictationsDir),
            kind: .meeting,
            count: 5,
            dateFrom: nil,
            dateTo: nil
        )

        XCTAssertEqual(items.count, 1)
        XCTAssertEqual(items.first?.preview, "No transcript captured.")
    }

    func testSearchSpeakerFilterUsesMatchingSpeakerUtterance() throws {
        let root = makeTempDir()
        defer { try? FileManager.default.removeItem(at: root) }

        let meetingsDir = root.appendingPathComponent("meetings", isDirectory: true)
        let dictationsDir = root.appendingPathComponent("dictations", isDirectory: true)
        try FileManager.default.createDirectory(at: meetingsDir, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: dictationsDir, withIntermediateDirectories: true)

        let meeting = """
        ---
        capture_type: meeting
        date: 2026-04-16
        time: 09:15:00
        duration: "0:18"
        ---

        # Product review

        ## Full Transcript

        [00:03] [System/Speaker 2] The product plan needs review.
        [00:08] [Mic/You] I agree, and the product plan still needs a test pass.
        """
        try meeting.write(
            to: meetingsDir.appendingPathComponent("Product review.md"),
            atomically: true,
            encoding: .utf8
        )

        let items = CLIContextStore.search(
            query: "product",
            speaker: "You",
            in: CLIContextDirectories(meetingsDir: meetingsDir, dictationsDir: dictationsDir),
            kind: .meeting,
            count: 5,
            dateFrom: nil,
            dateTo: nil
        )

        XCTAssertEqual(items.count, 1)
        XCTAssertEqual(items.first?.preview, "I agree, and the product plan still needs a test pass.")
    }

    private func makeTempDir() -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }
}
