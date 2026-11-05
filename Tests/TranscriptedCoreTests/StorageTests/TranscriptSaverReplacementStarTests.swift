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

    func testUnreadableReplacementMetadataKeepsOriginalBytesAndRejectsSave() throws {
        let url = directory.appendingPathComponent("Unreadable.md")
        let original = existingMeetingMarkdown(starred: true)
        try original.write(to: url, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o000], ofItemAtPath: url.path)
        defer { try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path) }
        XCTAssertNil(replace(url), "unknown protection metadata cannot authorize replacement")
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
        XCTAssertEqual(try String(contentsOf: url, encoding: .utf8), original)
    }

    func testMalformedReplacementMetadataDoesNotDropProtection() throws {
        // Shared parsing is LF-only. Other recognizable YAML prefixes remain
        // unknown metadata rather than becoming permission to overwrite.
        let prefixes = ["---\n", "---\r\n", "\u{FEFF}---\n", "\u{FEFF}---\r\n"]
        for (index, prefix) in prefixes.enumerated() {
            let url = directory.appendingPathComponent("Malformed-\(index).md")
            let original = prefix + "starred: true\n"
            try original.write(to: url, atomically: true, encoding: .utf8)
            XCTAssertNil(replace(url))
            XCTAssertEqual(try Data(contentsOf: url), Data(original.utf8))
        }
    }

    func testMissingReservedReplacementIsNotRecreated() throws {
        let url = directory.appendingPathComponent("Deleted.md")
        try existingMeetingMarkdown(starred: true).write(to: url, atomically: true, encoding: .utf8)
        let reservation = try XCTUnwrap(TranscriptSaver.beginReplacingTranscript(at: url))
        defer { TranscriptSaver.finishReplacingTranscript(reservation) }
        try FileManager.default.removeItem(at: url)
        XCTAssertNil(replace(url))
        XCTAssertFalse(FileManager.default.fileExists(atPath: url.path))
    }

    func testNewUnreservedExplicitDestinationCanBeCreated() {
        let url = directory.appendingPathComponent("New.md")
        XCTAssertEqual(replace(url), url)
        XCTAssertTrue(FileManager.default.fileExists(atPath: url.path))
    }

    func testReservedReplacementRejectsChangedIdentityWithoutOverwriting() throws {
        let url = directory.appendingPathComponent("Changed.md")
        try existingMeetingMarkdown(starred: true).write(to: url, atomically: true, encoding: .utf8)
        let reservation = try XCTUnwrap(TranscriptSaver.beginReplacingTranscript(at: url))
        defer { TranscriptSaver.finishReplacingTranscript(reservation) }
        let changed = existingMeetingMarkdown(starred: false)
            .replacingOccurrences(of: "4F0C2B9E-6A55-4D7B-9E62-1B2C3D4E5F60", with: UUID().uuidString)
        try changed.write(to: url, atomically: true, encoding: .utf8)
        XCTAssertNil(replace(url))
        XCTAssertEqual(try String(contentsOf: url, encoding: .utf8), changed)
    }

    // MARK: - Helpers

    func testReplacementAdmissionRejectsAnotherMeetingReusingTheSelectedPath() throws {
        let url = directory.appendingPathComponent("Reused.md")
        let selectedID = UUID(uuidString: "4F0C2B9E-6A55-4D7B-9E62-1B2C3D4E5F60")!
        try existingMeetingMarkdown(starred: true).write(to: url, atomically: true, encoding: .utf8)
        let replacement = existingMeetingMarkdown(starred: false)
            .replacingOccurrences(of: selectedID.uuidString, with: UUID().uuidString)
        // This is the model/snapshot wait: the selected file is removed and
        // another saved meeting takes its filename before reservation starts.
        try replacement.write(to: url, atomically: true, encoding: .utf8)
        XCTAssertNil(TranscriptSaver.beginReplacingTranscript(at: url, expectedTranscriptID: selectedID))
        XCTAssertEqual(try String(contentsOf: url, encoding: .utf8), replacement)
    }

    func testReplacementAdmissionAcceptsTheSelectedIdentityAndRejectsMissingTargets() throws {
        let url = directory.appendingPathComponent("Selected.md")
        let selectedID = UUID(uuidString: "4F0C2B9E-6A55-4D7B-9E62-1B2C3D4E5F60")!
        try existingMeetingMarkdown(starred: true).write(to: url, atomically: true, encoding: .utf8)
        let reservation = try XCTUnwrap(TranscriptSaver.beginReplacingTranscript(at: url, expectedTranscriptID: selectedID))
        TranscriptSaver.finishReplacingTranscript(reservation)
        try FileManager.default.removeItem(at: url)
        XCTAssertNil(TranscriptSaver.beginReplacingTranscript(at: url, expectedTranscriptID: selectedID))
        XCTAssertFalse(FileManager.default.fileExists(atPath: url.path), "a deleted target is never recreated")
    }

    func testUnchangedLegacyMeetingCanStillBeReprocessedAndGainsAnIdentity() throws {
        let url = directory.appendingPathComponent("Legacy.md")
        let legacy = existingMeetingMarkdown(starred: true).components(separatedBy: "\n")
            .filter { !$0.hasPrefix("capture_id:") && !$0.hasPrefix("transcript_id:") }.joined(separator: "\n")
        try legacy.write(to: url, atomically: true, encoding: .utf8)
        let early = try TranscriptReplacementExpectation.capture(at: url, requiringLegacy: true)
        let reservation = try XCTUnwrap(TranscriptSaver.beginReplacingTranscript(at: url, expectation: early))
        defer { TranscriptSaver.finishReplacingTranscript(reservation) }
        XCTAssertEqual(replace(url), url)
        let values = try XCTUnwrap(TranscriptFrontmatter.readValues(from: url))
        XCTAssertNotNil(TranscriptFrontmatter.captureID(in: values))
        XCTAssertTrue(TranscriptFrontmatter.isStarred(values: values))
    }

    func testDefaultCoreReservationKeepsLegacyCompatibility() throws {
        let url = directory.appendingPathComponent("LegacyDirect.md")
        let legacy = existingMeetingMarkdown(starred: false).components(separatedBy: "\n")
            .filter { !$0.hasPrefix("capture_id:") && !$0.hasPrefix("transcript_id:") }.joined(separator: "\n")
        try legacy.write(to: url, atomically: true, encoding: .utf8)
        let reservation = try XCTUnwrap(TranscriptSaver.beginReplacingTranscript(at: url))
        defer { TranscriptSaver.finishReplacingTranscript(reservation) }
        XCTAssertEqual(replace(url), url)
    }

    func testLegacyAdmissionRejectsChangedNewlyIdentifiedAndRecreatedTargets() throws {
        let url = directory.appendingPathComponent("LegacyChanged.md")
        let legacy = existingMeetingMarkdown(starred: false).components(separatedBy: "\n")
            .filter { !$0.hasPrefix("capture_id:") && !$0.hasPrefix("transcript_id:") }.joined(separator: "\n")
        for replacement in [legacy + "\nChanged body", existingMeetingMarkdown(starred: true), legacy] {
            try legacy.write(to: url, atomically: true, encoding: .utf8)
            let early = try TranscriptReplacementExpectation.capture(at: url, requiringLegacy: true)
            try FileManager.default.removeItem(at: url)
            try replacement.write(to: url, atomically: true, encoding: .utf8)
            XCTAssertNil(TranscriptSaver.beginReplacingTranscript(at: url, expectation: early))
            XCTAssertEqual(try String(contentsOf: url, encoding: .utf8), replacement)
        }
        try existingMeetingMarkdown(starred: false).write(to: url, atomically: true, encoding: .utf8)
        XCTAssertThrowsError(try TranscriptReplacementExpectation.capture(at: url, requiringLegacy: true),
                             "a selected legacy row cannot silently become a different modern capture")
    }

    func testReservedLegacyWriteRechecksTheExactOriginalBytes() throws {
        let url = directory.appendingPathComponent("LegacyWrite.md")
        let legacy = existingMeetingMarkdown(starred: true).components(separatedBy: "\n")
            .filter { !$0.hasPrefix("capture_id:") && !$0.hasPrefix("transcript_id:") }.joined(separator: "\n")
        try legacy.write(to: url, atomically: true, encoding: .utf8)
        let reservation = try XCTUnwrap(TranscriptSaver.beginReplacingTranscript(at: url))
        defer { TranscriptSaver.finishReplacingTranscript(reservation) }
        let changed = legacy + "\nDifferent protected body."
        try changed.write(to: url, atomically: true, encoding: .utf8)
        XCTAssertNil(replace(url))
        XCTAssertEqual(try String(contentsOf: url, encoding: .utf8), changed)
    }

    func testLegacyExpectationCannotBypassMalformedProtectionMetadata() throws {
        let url = directory.appendingPathComponent("MalformedLegacy.md")
        let raw = "---\ncapture_type: meeting\nstarred: true\nUnclosed header"
        try raw.write(to: url, atomically: true, encoding: .utf8)
        XCTAssertThrowsError(try TranscriptReplacementExpectation.capture(at: url, requiringLegacy: true))
        XCTAssertNil(TranscriptSaver.beginReplacingTranscript(at: url))
        XCTAssertEqual(try String(contentsOf: url, encoding: .utf8), raw)
    }

    func testLegacyExpectationIncludesInPlaceEditsBeyondTheFrontmatterPrefix() throws {
        let url = directory.appendingPathComponent("LongLegacy.md")
        let legacy = "---\ncapture_type: meeting\nstarred: true\n---\n\n" + String(repeating: "x", count: 2 << 20)
        try legacy.write(to: url, atomically: true, encoding: .utf8)
        let early = try TranscriptReplacementExpectation.capture(at: url, requiringLegacy: true)
        // Preserve inode, birth identity, length and the entire header while
        // changing a byte far beyond the bounded protection-metadata read.
        let handle = try FileHandle(forWritingTo: url)
        try handle.seek(toOffset: UInt64(legacy.utf8.count - 1))
        try handle.write(contentsOf: Data("y".utf8))
        try handle.close()
        XCTAssertFalse(try early.matches(at: url))
        XCTAssertNil(TranscriptSaver.beginReplacingTranscript(at: url, expectation: early))
        XCTAssertEqual(try Data(contentsOf: url).last, Character("y").asciiValue)
    }

    @discardableResult
    private func replace(_ transcriptURL: URL) -> URL? {
        TranscriptSaver.saveTranscript(
            syntheticResult(),
            transcriptId: UUID(uuidString: "4F0C2B9E-6A55-4D7B-9E62-1B2C3D4E5F60")!,
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
