import XCTest
@testable import TranscriptedCore

/// Re-transcribing a saved meeting overwrites its Markdown with a fresh file.
/// The user's star (`starred: true`) must come from the file being replaced at
/// the moment it is replaced, not from what the caller saw when the
/// re-transcription was requested: retention deletes an unstarred old
/// meeting's audio right after the save.
@available(macOS 14.0, *)
final class TranscriptSaverReplacementStarTests: XCTestCase {
    private var directory: URL!

    override func setUpWithError() throws {
        directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("TranscriptSaverReplacementStar-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        if let directory {
            try? FileManager.default.removeItem(at: directory)
        }
    }

    func testStarAddedAfterTheRequestIsKeptByTheReplacement() throws {
        let transcriptURL = directory.appendingPathComponent("2026-06-05 Quarterly Planning.md")
        // Unstarred when Re-transcribe is clicked...
        try existingMeetingMarkdown(starred: false).write(to: transcriptURL, atomically: true, encoding: .utf8)
        // ...then starred while the models load, before the replacement commits.
        try existingMeetingMarkdown(starred: true).write(to: transcriptURL, atomically: true, encoding: .utf8)

        let savedURL = replace(transcriptURL)

        XCTAssertEqual(savedURL, transcriptURL)
        let markdown = try String(contentsOf: transcriptURL, encoding: .utf8)
        XCTAssertTrue(markdown.contains("Fresh synthetic transcript."), "the replacement was written")
        let values = try XCTUnwrap(TranscriptFrontmatter.values(in: markdown))
        XCTAssertTrue(TranscriptFrontmatter.isStarred(values: values), "the new file keeps the star")
        XCTAssertEqual(starLines(in: markdown), 1, "exactly one flat starred line")
    }

    func testStarClearedBeforeTheReplacementIsNotPutBack() throws {
        let transcriptURL = directory.appendingPathComponent("2026-06-05 Design Review.md")
        // Starred when Re-transcribe is clicked, unstarred before it commits.
        try existingMeetingMarkdown(starred: true).write(to: transcriptURL, atomically: true, encoding: .utf8)
        try existingMeetingMarkdown(starred: false).write(to: transcriptURL, atomically: true, encoding: .utf8)

        replace(transcriptURL)

        let markdown = try String(contentsOf: transcriptURL, encoding: .utf8)
        let values = try XCTUnwrap(TranscriptFrontmatter.values(in: markdown))
        XCTAssertFalse(TranscriptFrontmatter.isStarred(values: values), "a cleared star stays cleared")
        XCTAssertEqual(starLines(in: markdown), 0)
    }

    func testFreshSaveIsNeverStarred() throws {
        let savedURL = try XCTUnwrap(TranscriptSaver.saveTranscript(
            syntheticResult(),
            transcriptId: UUID(),
            directory: directory,
            meetingTitle: "Standup",
            statsStore: ReplacementStarNoopStatsStore(),
            recordingDate: Date(timeIntervalSince1970: 1_780_000_000),
            transcriptionEngine: .parakeetLocal
        ))

        let markdown = try String(contentsOf: savedURL, encoding: .utf8)
        XCTAssertEqual(starLines(in: markdown), 0)
    }

    func testStarReadsOnlyTrueAsStarred() {
        XCTAssertTrue(TranscriptFrontmatter.isStarred(values: ["starred": "true"]))
        XCTAssertTrue(TranscriptFrontmatter.isStarred(values: ["starred": "TRUE"]))
        XCTAssertFalse(TranscriptFrontmatter.isStarred(values: ["starred": "false"]))
        XCTAssertFalse(TranscriptFrontmatter.isStarred(values: ["starred": "yes"]))
        XCTAssertFalse(TranscriptFrontmatter.isStarred(values: [:]))
    }

    // MARK: - Helpers

    @discardableResult
    private func replace(_ transcriptURL: URL) -> URL? {
        TranscriptSaver.saveTranscript(
            syntheticResult(),
            transcriptId: UUID(),
            directory: directory,
            meetingTitle: "Quarterly Planning",
            statsStore: ReplacementStarNoopStatsStore(),
            recordingDate: Date(timeIntervalSince1970: 1_780_000_000),
            targetURL: transcriptURL,
            transcriptionEngine: .parakeetLocal
        )
    }

    private func syntheticResult() -> TranscriptionResult {
        TranscriptionResult(
            micUtterances: [],
            systemUtterances: [
                TranscriptionUtterance(
                    start: 0,
                    end: 2,
                    channel: 1,
                    speakerId: 0,
                    persistentSpeakerId: nil,
                    matchSimilarity: nil,
                    transcript: "Fresh synthetic transcript."
                )
            ],
            duration: 2,
            processingTime: 0.5
        )
    }

    private func existingMeetingMarkdown(starred: Bool) -> String {
        """
        ---
        capture_id: "4F0C2B9E-6A55-4D7B-9E62-1B2C3D4E5F60"
        capture_type: meeting
        transcript_id: "4F0C2B9E-6A55-4D7B-9E62-1B2C3D4E5F60"
        title: "Quarterly Planning"
        date: 2026-06-05
        time: 09:00
        \(starred ? "starred: true\n" : "")---

        # Quarterly Planning

        ## Full Transcript

        **[00:00] [Mic/You]**
        Old synthetic transcript.
        """
    }

    private func starLines(in markdown: String) -> Int {
        let lines = TranscriptFrontmatter.lines(in: markdown) ?? []
        return lines.filter { $0.hasPrefix("starred:") }.count
    }
}

@available(macOS 14.0, *)
private final class ReplacementStarNoopStatsStore: StatsStore {
    func recordSession(_ metadata: RecordingMetadata) {}

    func getTotalRecordingsCount() -> Int { 0 }

    func getRecordings(from startDate: Date, to endDate: Date) -> [RecordingMetadata] { [] }

    func recordingExists(transcriptPath: String) -> Bool { false }
}
