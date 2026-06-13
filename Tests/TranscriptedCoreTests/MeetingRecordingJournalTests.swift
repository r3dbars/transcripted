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

        let session = store.begin(primaryMicURL: micURL, startedAt: Date(timeIntervalSince1970: 1_000))
        store.flush()
        var journal = try XCTUnwrap(MeetingRecordingJournalStore.load(at: journalURL))
        XCTAssertEqual(journal.state, .recording)
        XCTAssertEqual(journal.primaryMicFilename, "meeting_2026_mic.wav")
        XCTAssertEqual(journal.micSegments.map(\.filename), ["meeting_2026_mic.wav"])

        store.recordSystemAudio(temporaryDirectory.appendingPathComponent("meeting_2026_system.wav"), session: session)
        store.recordSegments([
            MicRecordingSegment(url: micURL),
            MicRecordingSegment(url: temporaryDirectory.appendingPathComponent("recovery.wav"), gapBeforeDuration: 1.5)
        ], session: session)
        store.markStopping(session: session)
        store.flush()
        journal = try XCTUnwrap(MeetingRecordingJournalStore.load(at: journalURL))
        XCTAssertEqual(journal.state, .stopping)
        XCTAssertEqual(journal.systemAudioFilename, "meeting_2026_system.wav")
        XCTAssertEqual(journal.micSegments.map(\.filename), ["meeting_2026_mic.wav", "recovery.wav"])
        XCTAssertEqual(journal.micSegments.last?.gapBefore ?? 0, 1.5, accuracy: 0.001)

        store.markFinalized(finalMicURL: temporaryDirectory.appendingPathComponent("meeting_2026_mic_merged.wav"), session: session)
        store.flush()
        journal = try XCTUnwrap(MeetingRecordingJournalStore.load(at: journalURL))
        XCTAssertEqual(journal.state, .finalized)
        XCTAssertEqual(journal.finalMicFilename, "meeting_2026_mic_merged.wav")

        store.clear()
        store.flush()
        XCTAssertFalse(FileManager.default.fileExists(atPath: journalURL.path))
    }

    func testLateFinalizeFromPreviousSessionLeavesNewJournalUntouched() throws {
        let store = MeetingRecordingJournalStore(directory: temporaryDirectory)
        let micA = temporaryDirectory.appendingPathComponent("meeting_A_mic.wav")
        let micB = temporaryDirectory.appendingPathComponent("meeting_B_mic.wav")
        let journalAURL = temporaryDirectory.appendingPathComponent("meeting_A_mic.recording.json")
        let journalBURL = temporaryDirectory.appendingPathComponent("meeting_B_mic.recording.json")

        let sessionA = store.begin(primaryMicURL: micA)
        store.markStopping(session: sessionA)

        // Recording B begins while A's finalize is still in flight — the
        // multi-segment merge in stop()'s cleanup can land seconds after a
        // timed-out bridge stop already let the next recording start.
        store.begin(primaryMicURL: micB)
        store.markFinalized(
            finalMicURL: temporaryDirectory.appendingPathComponent("meeting_A_mic_merged.wav"),
            session: sessionA
        )
        store.flush()

        let journalB = try XCTUnwrap(MeetingRecordingJournalStore.load(at: journalBURL))
        XCTAssertEqual(journalB.state, .recording)
        XCTAssertNil(journalB.finalMicFilename, "A's late finalize must not write A's merged file into B's journal")

        let journalA = try XCTUnwrap(MeetingRecordingJournalStore.load(at: journalAURL))
        XCTAssertEqual(journalA.state, .stopping)
        XCTAssertNil(journalA.finalMicFilename, "A's journal keeps its last owned state for the recovery scan")
    }

    func testLateWriteAfterJournalRemovalDoesNotResurrectIt() throws {
        let store = MeetingRecordingJournalStore(directory: temporaryDirectory)
        let micURL = temporaryDirectory.appendingPathComponent("meeting_done_mic.wav")
        let journalURL = temporaryDirectory.appendingPathComponent("meeting_done_mic.recording.json")

        let session = store.begin(primaryMicURL: micURL)
        store.markStopping(session: session)
        store.flush()
        XCTAssertTrue(FileManager.default.fileExists(atPath: journalURL.path))

        // Durable handoff (failed-queue entry persisted, or transcript saved)
        // removes the file through the static helper, which has no access to
        // this store instance's in-memory state.
        MeetingRecordingJournalStore.removeJournal(forMicAudioURL: micURL)
        XCTAssertFalse(FileManager.default.fileExists(atPath: journalURL.path))

        // A late write from the same session must drop, not re-create the file.
        store.markFinalized(finalMicURL: micURL, session: session)
        store.flush()
        XCTAssertFalse(
            FileManager.default.fileExists(atPath: journalURL.path),
            "a write after durable handoff must not resurrect the journal"
        )
    }

    func testStopWithNoActiveSessionDoesNotResurrectRemovedJournal() throws {
        let paths = CoreStoragePaths(
            transcripts: temporaryDirectory.appendingPathComponent("transcripts", isDirectory: true),
            speakerDB: temporaryDirectory.appendingPathComponent("speakers.sqlite"),
            statsDB: temporaryDirectory.appendingPathComponent("stats.sqlite"),
            failedQueue: temporaryDirectory.appendingPathComponent("failed_transcriptions.json"),
            speakerClips: temporaryDirectory.appendingPathComponent("speaker_clips", isDirectory: true),
            audioCaptures: temporaryDirectory.appendingPathComponent("audio", isDirectory: true),
            logs: temporaryDirectory.appendingPathComponent("logs", isDirectory: true)
        )
        try FileManager.default.createDirectory(at: paths.audioCaptures, withIntermediateDirectories: true)

        let audio = Audio(paths: paths)
        let micURL = paths.audioCaptures.appendingPathComponent("meeting_prev_mic.wav")
        let journalURL = paths.audioCaptures.appendingPathComponent("meeting_prev_mic.recording.json")

        // A previous meeting finished and reached durable handoff: its journal
        // file is removed, but the store instance still holds the journal in
        // memory because nothing in production calls clear().
        let session = audio.recordingJournal.begin(primaryMicURL: micURL)
        audio.recordingJournal.markFinalized(finalMicURL: micURL, session: session)
        audio.recordingJournal.flush()
        MeetingRecordingJournalStore.removeJournal(forMicAudioURL: micURL)
        XCTAssertFalse(FileManager.default.fileExists(atPath: journalURL.path))

        // A failed start (e.g. bridge start timeout) calls stop() without an
        // active recording session.
        let stopFinished = expectation(description: "stop completion fired")
        audio.onRecordingComplete = { _, _ in stopFinished.fulfill() }
        audio.stop()
        wait(for: [stopFinished], timeout: 5.0)
        audio.recordingJournal.flush()

        XCTAssertFalse(
            FileManager.default.fileExists(atPath: journalURL.path),
            "stop() with no active session must not re-persist the previous meeting's journal"
        )
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
