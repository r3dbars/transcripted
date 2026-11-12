import XCTest
@testable import TranscriptedCore

/// Promise: a Stop that lands while a meeting start is opening its recording
/// journal either takes that journal (so it can mark it stopped and
/// finalized) or no journal is opened at all. A journal opened after Stop
/// already took the empty slot would stay "recording" with nobody to close it,
/// and launch recovery would bring back a meeting the user already stopped.
final class MeetingJournalStartStopRaceTests: XCTestCase {
    private func makeAudio() throws -> Audio {
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
        ))
    }

    private func makeSession() -> MeetingRecordingJournalSession {
        MeetingRecordingJournalSession(
            journalURL: URL(fileURLWithPath: "/nonexistent/meeting_test_mic.recording.json")
        )
    }

    func testStopBeforeTheJournalOpensMeansNoJournalIsOpened() throws {
        let audio = try makeAudio()
        audio.prepareForNewRecordingStart()
        let startGeneration = audio.recordingSessionGeneration
        // Stop advances the generation and takes the (still empty) slot.
        audio.beginRecordingSessionGeneration()
        XCTAssertNil(audio.takeJournalSession())

        var opened = false
        let session = audio.openJournalSessionIfCurrent(sessionGeneration: startGeneration) {
            opened = true
            return makeSession()
        }

        XCTAssertNil(session)
        XCTAssertFalse(opened, "A stopped start must not open a journal")
        XCTAssertNil(audio.journalSession)
    }

    func testStopLandingWhileTheJournalOpensTakesThatJournal() throws {
        let audio = try makeAudio()
        audio.prepareForNewRecordingStart()
        let startGeneration = audio.recordingSessionGeneration
        let expected = makeSession()

        let stopAdvanced = DispatchSemaphore(value: 0)
        let stopTook = DispatchSemaphore(value: 0)
        let takenByStop = TakenSession()
        var stopFinishedDuringOpen = false
        let opened = audio.openJournalSessionIfCurrent(sessionGeneration: startGeneration) {
            // Stop arrives mid-open, the way stop() does it: advance the
            // generation, then take the session.
            Thread.detachNewThread {
                audio.beginRecordingSessionGeneration()
                stopAdvanced.signal()
                takenByStop.value = audio.takeJournalSession()
                stopTook.signal()
            }
            stopAdvanced.wait()
            // Give a Stop that is not held off every chance to take the
            // empty slot before this open publishes. Only orders the race;
            // nothing asserts on elapsed time.
            stopFinishedDuringOpen = stopTook.wait(timeout: .now() + 0.3) == .success
            return expected
        }
        if !stopFinishedDuringOpen { stopTook.wait() }

        XCTAssertEqual(opened, expected)
        XCTAssertEqual(takenByStop.value, expected, "Stop must receive the journal the start opened")
        XCTAssertNil(audio.journalSession, "Stop's take leaves nothing behind for a later writer")
    }
}

/// Written once on the Stop thread before `stopTook` signals, read after.
private final class TakenSession: @unchecked Sendable {
    var value: MeetingRecordingJournalSession?
}
