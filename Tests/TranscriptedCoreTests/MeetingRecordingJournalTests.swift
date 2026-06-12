import XCTest
@testable import TranscriptedCore

final class MeetingRecordingJournalTests: XCTestCase {
    private var temporaryDirectory: URL!

    override func setUpWithError() throws {
        temporaryDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("MeetingRecordingJournalTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: temporaryDirectory, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        if let temporaryDirectory {
            try? FileManager.default.removeItem(at: temporaryDirectory)
        }
        temporaryDirectory = nil
    }

    func testLifecycleWritesStatesAndClearRemoves() throws {
        let store = MeetingRecordingJournalStore(directory: temporaryDirectory)
        let micURL = temporaryDirectory.appendingPathComponent("meeting_2026_mic.wav")
        let journalURL = temporaryDirectory.appendingPathComponent("meeting_2026_mic.recording.json")

        store.begin(primaryMicURL: micURL, startedAt: Date(timeIntervalSince1970: 1_000))
        store.flush()
        var journal = try XCTUnwrap(MeetingRecordingJournalStore.load(at: journalURL))
        XCTAssertEqual(journal.state, .recording)
        XCTAssertEqual(journal.primaryMicFilename, "meeting_2026_mic.wav")
        XCTAssertEqual(journal.micSegments.map(\.filename), ["meeting_2026_mic.wav"])

        store.recordSystemAudio(temporaryDirectory.appendingPathComponent("meeting_2026_system.wav"))
        store.recordSegments([
            MicRecordingSegment(url: micURL),
            MicRecordingSegment(url: temporaryDirectory.appendingPathComponent("recovery.wav"), gapBeforeDuration: 1.5)
        ])
        store.markStopping()
        store.flush()
        journal = try XCTUnwrap(MeetingRecordingJournalStore.load(at: journalURL))
        XCTAssertEqual(journal.state, .stopping)
        XCTAssertEqual(journal.systemAudioFilename, "meeting_2026_system.wav")
        XCTAssertEqual(journal.micSegments.map(\.filename), ["meeting_2026_mic.wav", "recovery.wav"])
        XCTAssertEqual(journal.micSegments.last?.gapBefore ?? 0, 1.5, accuracy: 0.001)

        store.markFinalized(finalMicURL: temporaryDirectory.appendingPathComponent("meeting_2026_mic_merged.wav"))
        store.flush()
        journal = try XCTUnwrap(MeetingRecordingJournalStore.load(at: journalURL))
        XCTAssertEqual(journal.state, .finalized)
        XCTAssertEqual(journal.finalMicFilename, "meeting_2026_mic_merged.wav")

        store.clear()
        store.flush()
        XCTAssertFalse(FileManager.default.fileExists(atPath: journalURL.path))
    }

    func testJournalURLsFindsOnlyJournalFiles() throws {
        FileManager.default.createFile(
            atPath: temporaryDirectory.appendingPathComponent("a.recording.json").path,
            contents: Data()
        )
        FileManager.default.createFile(
            atPath: temporaryDirectory.appendingPathComponent("b.wav").path,
            contents: Data()
        )

        let found = MeetingRecordingJournalStore.journalURLs(in: temporaryDirectory)
        XCTAssertEqual(found.map(\.lastPathComponent), ["a.recording.json"])
    }

    func testRemoveJournalMatchesMergedStem() throws {
        let journalURL = temporaryDirectory.appendingPathComponent("meeting_2026_mic.recording.json")
        FileManager.default.createFile(atPath: journalURL.path, contents: Data())

        // The durable handoff often sees the merged file, not the original.
        MeetingRecordingJournalStore.removeJournal(
            forMicAudioURL: temporaryDirectory.appendingPathComponent("meeting_2026_mic_merged.wav")
        )
        XCTAssertFalse(FileManager.default.fileExists(atPath: journalURL.path))
    }

    func testRemoveJournalMatchesExactStem() throws {
        let journalURL = temporaryDirectory.appendingPathComponent("meeting_2026_mic.recording.json")
        FileManager.default.createFile(atPath: journalURL.path, contents: Data())

        MeetingRecordingJournalStore.removeJournal(
            forMicAudioURL: temporaryDirectory.appendingPathComponent("meeting_2026_mic.wav")
        )
        XCTAssertFalse(FileManager.default.fileExists(atPath: journalURL.path))
    }
}
