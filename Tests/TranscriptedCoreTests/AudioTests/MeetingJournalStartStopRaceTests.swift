import XCTest
@testable import TranscriptedCore

/// Promise: a Stop that lands while a meeting start is opening its recording
/// journal either takes that journal (so it can mark it stopped and
/// finalized) or no journal is opened at all. A journal opened after Stop
/// already took the empty slot would stay "recording" with nobody to close it,
/// and launch recovery would bring back a meeting the user already stopped.
final class MeetingJournalStartStopRaceTests: XCTestCase {
    private func makeAudio(persist: ((Data, URL) throws -> Void)? = nil) throws -> Audio {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("MeetingJournalStartStopRaceTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: root) }
        return Audio(paths: CoreStoragePaths(
            transcripts: root.appendingPathComponent("captures/meetings", isDirectory: true),
            speakerDB: root.appendingPathComponent("state/speakers.sqlite"),
            statsDB: root.appendingPathComponent("state/stats.sqlite"),
            failedQueue: root.appendingPathComponent("state/failed_transcriptions.json"),
            speakerClips: root.appendingPathComponent("tmp/recordings/speaker_clips", isDirectory: true),
            audioCaptures: root.appendingPathComponent("tmp/recordings", isDirectory: true),
            logs: root.appendingPathComponent("logs", isDirectory: true)
        ), systemAudioCaptureForTesting: nil, initialJournalPersistenceForTesting: persist)
    }

    func testStoppedStartCannotOpenJournalInSuccessorGeneration() throws {
        let audio = try makeAudio()
        let directory = audio.paths.audioCaptures
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        audio.prepareForNewRecordingStart()
        let generation = audio.recordingSessionGeneration
        let stopped = expectation(description: "stop completed")
        audio.onRecordingComplete = { _, _ in stopped.fulfill() }
        audio.stop()
        wait(for: [stopped], timeout: 5)
        audio.prepareForNewRecordingStart()
        XCTAssertThrowsError(try audio.openJournalSessionIfCurrent(
            primaryMicURL: directory.appendingPathComponent("meeting_stale_mic.wav"),
            sessionGeneration: generation
        )) { XCTAssertTrue($0 is AudioCaptureStaleSessionError) }
        XCTAssertTrue(MeetingRecordingJournalStore.journalURLs(in: directory).isEmpty)
        XCTAssertNil(audio.journalSession)
    }

    @MainActor
    func testStopDuringPersistPreventsStaleTrackAdmissionAcrossSuccessorStart() throws {
        try exerciseStopDuringPersist(failOldWrite: false)
    }

    @MainActor
    func testFailedFirstPersistCannotTransferOwnershipToRecovery() throws {
        try exerciseStopDuringPersist(failOldWrite: true)
    }

    @MainActor
    private func exerciseStopDuringPersist(failOldWrite: Bool) throws {
        let persisting = expectation(description: "old start entered first disk write")
        let release = DispatchSemaphore(value: 0)
        let audio = try makeAudio { data, url in
            if url.lastPathComponent != "meeting_new_mic.recording.json" {
                persisting.fulfill()
                // Deadlock escape only. Stop must return and release this gate.
                guard release.wait(timeout: .now() + 10) == .success else {
                    XCTFail("Stop waited for initial journal persistence")
                    throw CocoaError(.fileWriteUnknown)
                }
            }
            try data.write(to: url, options: .atomic)
            if failOldWrite, url.lastPathComponent != "meeting_new_mic.recording.json" {
                throw CocoaError(.fileWriteUnknown)
            }
        }
        let directory = audio.paths.audioCaptures
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        audio.prepareForNewRecordingStart()
        let oldGeneration = audio.recordingSessionGeneration
        let oldStartFinished = expectation(description: "old start observed Stop")
        DispatchQueue.global().async {
            do {
                _ = try audio.openMeetingStartTracks(
                    capturesSystemAudio: true,
                    sessionGeneration: oldGeneration
                )
                XCTFail("Stopped start returned as current")
            } catch {
                XCTAssertTrue(error is AudioCaptureStaleSessionError)
            }
            oldStartFinished.fulfill()
        }
        wait(for: [persisting], timeout: 5)
        let completed = expectation(description: "old stop completed without recovery ownership")
        audio.onRecordingCompleteWithGeneration = { _, mic, system, disposition in
            XCTAssertNil(system)
            XCTAssertNil(mic)
            XCTAssertEqual(disposition, .finalized)
            completed.fulfill()
        }
        audio.stop()
        XCTAssertNil(audio.journalSession)
        XCTAssertFalse(audio.abandonRecordingJournalFinalization(forStopGeneration: audio.recordingSessionGeneration))
        audio.prepareForNewRecordingStart()
        let successorGeneration = audio.recordingSessionGeneration
        release.signal()
        let successorMic = directory.appendingPathComponent("meeting_new_mic.wav")
        let successor = try audio.openJournalSessionIfCurrent(primaryMicURL: successorMic, sessionGeneration: successorGeneration)
        wait(for: [oldStartFinished, completed], timeout: 5)
        audio.recordingJournal.flush()

        XCTAssertEqual(audio.journalSession, successor)
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: directory.path),
                       ["meeting_new_mic.recording.json"])
        let newJournal = directory.appendingPathComponent("meeting_new_mic.recording.json")
        XCTAssertEqual(MeetingRecordingJournalStore.load(at: newJournal)?.state, .recording)
        XCTAssertTrue(MeetingRecordingJournalStore.isOwnedByLiveFinalizer(at: newJournal))
    }

    /// Promise: the start's mic WAV always has an owner. Either Stop's
    /// snapshot names it, or the start learns Stop won before it creates the
    /// file, so a header-only WAV is never left with no journal and no owner.
    func testStopBeforeTheMicFileIsPublishedRejectsThePublish() throws {
        let audio = try makeAudio()
        audio.prepareForNewRecordingStart()
        let startGeneration = audio.recordingSessionGeneration
        audio.beginRecordingSessionGeneration()
        let stopSnapshot = audio.snapshotStartedMicFiles()

        let micURL = URL(fileURLWithPath: "/nonexistent/meeting_test_mic.wav")
        XCTAssertFalse(audio.publishMeetingMicStartFileIfCurrent(micURL, sessionGeneration: startGeneration))
        XCTAssertNil(stopSnapshot.primaryURL)
        XCTAssertNil(audio.snapshotStartedMicFiles().primaryURL)
    }

    func testStopAfterTheMicFileIsPublishedSeesIt() throws {
        let audio = try makeAudio()
        audio.prepareForNewRecordingStart()
        let startGeneration = audio.recordingSessionGeneration
        let micURL = URL(fileURLWithPath: "/nonexistent/meeting_test_mic.wav")

        XCTAssertTrue(audio.publishMeetingMicStartFileIfCurrent(micURL, sessionGeneration: startGeneration))
        audio.beginRecordingSessionGeneration()
        let stopSnapshot = audio.snapshotStartedMicFiles()

        XCTAssertEqual(stopSnapshot.primaryURL, micURL)
        XCTAssertEqual(stopSnapshot.segments.map(\.url), [micURL])
    }
}
