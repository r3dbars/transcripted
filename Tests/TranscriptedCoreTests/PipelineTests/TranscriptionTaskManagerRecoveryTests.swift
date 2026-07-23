import AVFoundation
import Combine
import FluidAudio
import XCTest
@testable import TranscriptedCore

@available(macOS 14.0, *)
@MainActor
final class TranscriptionTaskManagerRecoveryTests: XCTestCase {
    private var tempDirectory: URL!

    override func setUpWithError() throws {
        tempDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("RecoveryTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tempDirectory, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        if let tempDirectory {
            try? FileManager.default.removeItem(at: tempDirectory)
        }
        tempDirectory = nil
    }

    func testRecoversOrphanedRecordingWithCorruptHeader() async throws {
        let (manager, paths) = makeManager()

        let micURL = paths.audioCaptures.appendingPathComponent("meeting_crash_mic.wav")
        try writeMonoWAV(to: micURL, sampleRate: 48_000, samples: Array(repeating: 0.5, count: 9_600))
        try corruptHeaderSizes(at: micURL)
        try backdate(micURL)
        XCTAssertEqual(try AVAudioFile(forReading: micURL).length, 0)

        let startedAt = Date(timeIntervalSince1970: 1_750_000_000)
        let journalURL = try writeJournal(
            in: paths.audioCaptures,
            primaryMicFilename: "meeting_crash_mic.wav",
            segments: [.init(filename: "meeting_crash_mic.wav", gapBefore: 0)],
            startedAt: startedAt
        )

        let recovered = await manager.recoverOrphanedRecordings(in: paths.audioCaptures)

        XCTAssertEqual(recovered, 1)
        XCTAssertFalse(FileManager.default.fileExists(atPath: journalURL.path))

        let entry = try XCTUnwrap(manager.failedTranscriptionManager.failedTranscriptions.first)
        XCTAssertEqual(entry.micAudioURL, micURL)
        XCTAssertEqual(entry.recordingDate, startedAt)
        XCTAssertTrue(entry.isRetryable)

        // The header repair must make the recovered audio actually readable.
        XCTAssertEqual(try AVAudioFile(forReading: micURL).length, 9_600)
    }

    func testSkipsJournalWhoseAudioIsRecentlyWritten() async throws {
        let (manager, paths) = makeManager()

        let micURL = paths.audioCaptures.appendingPathComponent("meeting_live_mic.wav")
        try writeMonoWAV(to: micURL, sampleRate: 48_000, samples: Array(repeating: 0.5, count: 4_800))
        // No backdating: the file looks actively written, as it would if a
        // second Transcripted process were recording into the shared scratch.
        let journalURL = try writeJournal(
            in: paths.audioCaptures,
            primaryMicFilename: "meeting_live_mic.wav",
            segments: [.init(filename: "meeting_live_mic.wav", gapBefore: 0)],
            startedAt: Date()
        )

        let recovered = await manager.recoverOrphanedRecordings(
            in: paths.audioCaptures,
            livenessWindow: 120,
            waitForRecentJournals: false
        )

        XCTAssertEqual(recovered, 0)
        XCTAssertTrue(FileManager.default.fileExists(atPath: journalURL.path))
        XCTAssertTrue(manager.failedTranscriptionManager.failedTranscriptions.isEmpty)
        XCTAssertTrue(FileManager.default.fileExists(atPath: micURL.path))
    }

    func testRecoveryWaitsForLiveStopFinalizerOwnership() async throws {
        let (manager, paths) = makeManager()
        let micURL = paths.audioCaptures.appendingPathComponent("meeting_live_finalizer_mic.wav")
        try writeMonoWAV(to: micURL, sampleRate: 48_000, samples: Array(repeating: 0.5, count: 4_800))
        try backdate(micURL)

        let store = MeetingRecordingJournalStore(directory: paths.audioCaptures)
        let session = store.begin(
            primaryMicURL: micURL,
            startedAt: Date(timeIntervalSince1970: 1_000)
        )
        store.markStopping(session: session)
        store.flush()
        let journalURL = try XCTUnwrap(
            MeetingRecordingJournalStore.journalURLs(in: paths.audioCaptures).first
        )
        try backdate(journalURL)

        let failedID = UUID()
        XCTAssertTrue(manager.addFailedTranscriptionRetainingAvailableAudio(
            micAudioURL: micURL,
            systemAudioURL: nil,
            errorMessage: "Recording stop timed out before audio files were finalized.",
            taskId: failedID,
            archiveAudio: false,
            clearRecordingJournalAfterPersistence: false
        ))

        let whileFinalizing = await manager.recoverOrphanedRecordings(
            in: paths.audioCaptures,
            livenessWindow: 0,
            waitForRecentJournals: false
        )
        XCTAssertEqual(whileFinalizing, 0)
        XCTAssertTrue(FileManager.default.fileExists(atPath: journalURL.path))
        XCTAssertEqual(manager.failedTranscriptionManager.failedTranscriptions.first?.id, failedID)

        store.markFinalized(finalMicURL: micURL, session: session)
        store.flush()
        let afterFinalizing = await manager.recoverOrphanedRecordings(
            in: paths.audioCaptures,
            livenessWindow: 0,
            waitForRecentJournals: false
        )
        XCTAssertEqual(afterFinalizing, 1)
        XCTAssertFalse(FileManager.default.fileExists(atPath: journalURL.path))
        XCTAssertEqual(manager.failedTranscriptionManager.failedTranscriptions.count, 1)
        XCTAssertEqual(manager.failedTranscriptionManager.failedTranscriptions.first?.id, failedID)
    }

    func testRecoveryPromotesExistingSystemOnlyTimeoutRowWithoutDuplicatingIt() async throws {
        let (manager, paths) = makeManager()
        let missingMicURL = paths.audioCaptures.appendingPathComponent("meeting_system_only_mic.wav")
        let systemURL = paths.audioCaptures.appendingPathComponent("meeting_system_only_system.wav")
        try writeMonoWAV(to: systemURL, sampleRate: 48_000, samples: Array(repeating: 0.5, count: 4_800))
        try backdate(systemURL)
        let journalURL = try writeJournal(
            in: paths.audioCaptures,
            primaryMicFilename: missingMicURL.lastPathComponent,
            segments: [.init(filename: missingMicURL.lastPathComponent, gapBefore: 0)],
            startedAt: Date(timeIntervalSince1970: 1_000),
            state: .stopping,
            systemAudioFilename: systemURL.lastPathComponent
        )

        let failedID = UUID()
        XCTAssertTrue(manager.addFailedTranscriptionRetainingAvailableAudio(
            micAudioURL: nil,
            systemAudioURL: systemURL,
            errorMessage: "Recording stop timed out before microphone audio was finalized.",
            taskId: failedID,
            archiveAudio: false,
            clearRecordingJournalAfterPersistence: false
        ))
        XCTAssertEqual(manager.failedTranscriptionManager.failedTranscriptions.count, 1)

        let recovered = await manager.recoverOrphanedRecordings(
            in: paths.audioCaptures,
            livenessWindow: 0,
            waitForRecentJournals: false
        )

        XCTAssertEqual(recovered, 1)
        XCTAssertFalse(FileManager.default.fileExists(atPath: journalURL.path))
        XCTAssertEqual(manager.failedTranscriptionManager.failedTranscriptions.count, 1)
        XCTAssertEqual(manager.failedTranscriptionManager.failedTranscriptions.first?.id, failedID)
        XCTAssertEqual(
            manager.failedTranscriptionManager.failedTranscriptions.first?.systemAudioURL,
            systemURL
        )
    }

    func testRemovesStaleJournalWithNoAudio() async throws {
        let (manager, paths) = makeManager()

        let journalURL = try writeJournal(
            in: paths.audioCaptures,
            primaryMicFilename: "meeting_gone_mic.wav",
            segments: [.init(filename: "meeting_gone_mic.wav", gapBefore: 0)],
            startedAt: Date(timeIntervalSince1970: 1_000)
        )

        let recovered = await manager.recoverOrphanedRecordings(in: paths.audioCaptures)

        XCTAssertEqual(recovered, 0)
        XCTAssertFalse(FileManager.default.fileExists(atPath: journalURL.path))
        XCTAssertTrue(manager.failedTranscriptionManager.failedTranscriptions.isEmpty)
    }

    func testStaleJournalDirectoryIsNeverRecursivelyRemoved() async throws {
        let (manager, paths) = makeManager()
        let journalDirectory = paths.audioCaptures
            .appendingPathComponent("directory.recording.json", isDirectory: true)
        try FileManager.default.createDirectory(at: journalDirectory, withIntermediateDirectories: true)
        let sentinelURL = journalDirectory.appendingPathComponent("keep.txt")
        FileManager.default.createFile(atPath: sentinelURL.path, contents: Data("keep".utf8))

        let recovered = await manager.recoverOrphanedRecordings(in: paths.audioCaptures)

        XCTAssertEqual(recovered, 0)
        var isDirectory: ObjCBool = false
        XCTAssertTrue(FileManager.default.fileExists(atPath: journalDirectory.path, isDirectory: &isDirectory))
        XCTAssertTrue(isDirectory.boolValue)
        XCTAssertTrue(FileManager.default.fileExists(atPath: sentinelURL.path))
        XCTAssertTrue(manager.failedTranscriptionManager.failedTranscriptions.isEmpty)
    }

    func testCorruptSystemOnlyJournalSurvivesRecoveryAndPendingDeletionRelaunch() async throws {
        let (manager, paths) = makeManager()
        let placeholderURL = paths.audioCaptures.appendingPathComponent("corrupt-system-placeholder.wav")
        let hiddenMicURL = paths.audioCaptures.appendingPathComponent("corrupt-hidden-mic.wav")
        let systemURL = paths.audioCaptures.appendingPathComponent("corrupt-system.wav")
        let journalURL = paths.audioCaptures.appendingPathComponent("corrupt-hidden-mic.recording.json")
        for url in [placeholderURL, hiddenMicURL, systemURL] {
            FileManager.default.createFile(atPath: url.path, contents: Data("owned".utf8))
        }
        try Data("not-json".utf8).write(to: journalURL, options: .atomic)

        let failedID = UUID()
        XCTAssertTrue(manager.failedTranscriptionManager.addFailedTranscription(
            id: failedID,
            micAudioURL: placeholderURL,
            systemAudioURL: systemURL,
            errorMessage: "Recording stop timed out before audio files were finalized."
        ))
        XCTAssertFalse(manager.failedTranscriptionManager.deleteFailedTranscription(id: failedID))

        let recovered = await manager.recoverOrphanedRecordings(in: paths.audioCaptures)

        XCTAssertEqual(recovered, 0)
        for url in [placeholderURL, hiddenMicURL, systemURL, journalURL] {
            XCTAssertTrue(FileManager.default.fileExists(atPath: url.path))
        }

        let reloaded = FailedTranscriptionManager(paths: paths)
        XCTAssertEqual(reloaded.failedTranscriptions.map(\.id), [failedID])
        let pendingDeletionURL = paths.failedQueue.deletingLastPathComponent()
            .appendingPathComponent(FailedTranscriptionManager.pendingDeletionFilename)
        XCTAssertTrue(FileManager.default.fileExists(atPath: pendingDeletionURL.path))
        for url in [placeholderURL, hiddenMicURL, systemURL, journalURL] {
            XCTAssertTrue(FileManager.default.fileExists(atPath: url.path))
        }
    }

    func testRecoversMultiSegmentRecordingByMerging() async throws {
        let (manager, paths) = makeManager()

        let primaryURL = paths.audioCaptures.appendingPathComponent("meeting_multi_mic.wav")
        let recoveryURL = paths.audioCaptures.appendingPathComponent("meeting_multi_mic_recovery.wav")
        try writeMonoWAV(to: primaryURL, sampleRate: 48_000, samples: Array(repeating: 0.3, count: 4_800))
        try writeMonoWAV(to: recoveryURL, sampleRate: 48_000, samples: Array(repeating: 0.6, count: 4_800))
        try backdate(primaryURL)
        try backdate(recoveryURL)

        _ = try writeJournal(
            in: paths.audioCaptures,
            primaryMicFilename: "meeting_multi_mic.wav",
            segments: [
                .init(filename: "meeting_multi_mic.wav", gapBefore: 0),
                .init(filename: "meeting_multi_mic_recovery.wav", gapBefore: 0.1)
            ],
            startedAt: Date(timeIntervalSince1970: 1_000)
        )

        let recovered = await manager.recoverOrphanedRecordings(in: paths.audioCaptures)

        XCTAssertEqual(recovered, 1)
        let entry = try XCTUnwrap(manager.failedTranscriptionManager.failedTranscriptions.first)
        XCTAssertEqual(entry.micAudioURL.lastPathComponent, "meeting_multi_mic_merged.wav")

        let merged = try AVAudioFile(forReading: entry.micAudioURL)
        XCTAssertGreaterThan(merged.length, 3_000)
    }

    func testRecoveryPromotesExistingTimeoutRowWithoutDuplicatingIt() async throws {
        let (manager, paths) = makeManager()
        let primaryURL = paths.audioCaptures.appendingPathComponent("meeting_timeout_mic.wav")
        let recoveryURL = paths.audioCaptures.appendingPathComponent("meeting_timeout_recovery.wav")
        let failedID = UUID()
        try writeMonoWAV(to: primaryURL, sampleRate: 48_000, samples: Array(repeating: 0.3, count: 4_800))
        try writeMonoWAV(to: recoveryURL, sampleRate: 48_000, samples: Array(repeating: 0.6, count: 4_800))
        try backdate(primaryURL)
        try backdate(recoveryURL)

        let journalURL = try writeJournal(
            in: paths.audioCaptures,
            primaryMicFilename: primaryURL.lastPathComponent,
            segments: [
                .init(filename: primaryURL.lastPathComponent, gapBefore: 0),
                .init(filename: recoveryURL.lastPathComponent, gapBefore: 0.1)
            ],
            startedAt: Date(timeIntervalSince1970: 1_000),
            state: .stopping
        )
        XCTAssertTrue(manager.addFailedTranscriptionRetainingAvailableAudio(
            micAudioURL: primaryURL,
            systemAudioURL: nil,
            errorMessage: "Recording stop timed out before audio files were finalized.",
            taskId: failedID,
            archiveAudio: false,
            clearRecordingJournalAfterPersistence: false
        ))
        XCTAssertTrue(FileManager.default.fileExists(atPath: journalURL.path))

        let recovered = await manager.recoverOrphanedRecordings(in: paths.audioCaptures)

        XCTAssertEqual(recovered, 1)
        XCTAssertFalse(FileManager.default.fileExists(atPath: journalURL.path))
        XCTAssertEqual(manager.failedTranscriptionManager.failedTranscriptions.count, 1)
        let entry = try XCTUnwrap(manager.failedTranscriptionManager.failedTranscriptions.first)
        XCTAssertEqual(entry.id, failedID)
        XCTAssertEqual(entry.micAudioURL.lastPathComponent, "meeting_timeout_mic_merged.wav")
    }

    func testLateCallbackAfterRecoveryKeepsArchivedAudioPaths() async throws {
        let retainedAudioDirectory = tempDirectory
            .appendingPathComponent("transcripts", isDirectory: true)
            .appendingPathComponent("audio", isDirectory: true)
        let (manager, paths) = makeManager(retainedAudioDirectory: retainedAudioDirectory)
        let primaryURL = paths.audioCaptures.appendingPathComponent("meeting_late_mic.wav")
        let recoveryURL = paths.audioCaptures.appendingPathComponent("meeting_late_recovery.wav")
        let lateCallbackURL = paths.audioCaptures.appendingPathComponent("meeting_late_mic_merged.wav")
        let failedID = UUID()
        try writeMonoWAV(to: primaryURL, sampleRate: 48_000, samples: Array(repeating: 0.3, count: 4_800))
        try writeMonoWAV(to: recoveryURL, sampleRate: 48_000, samples: Array(repeating: 0.6, count: 4_800))
        try backdate(primaryURL)
        try backdate(recoveryURL)

        _ = try writeJournal(
            in: paths.audioCaptures,
            primaryMicFilename: primaryURL.lastPathComponent,
            segments: [
                .init(filename: primaryURL.lastPathComponent, gapBefore: 0),
                .init(filename: recoveryURL.lastPathComponent, gapBefore: 0.1)
            ],
            startedAt: Date(timeIntervalSince1970: 1_000),
            state: .stopping
        )
        XCTAssertTrue(manager.addFailedTranscriptionRetainingAvailableAudio(
            micAudioURL: primaryURL,
            systemAudioURL: nil,
            errorMessage: "Recording stop timed out before audio files were finalized.",
            taskId: failedID,
            archiveAudio: false,
            clearRecordingJournalAfterPersistence: false
        ))

        let recoveredCount = await manager.recoverOrphanedRecordings(in: paths.audioCaptures)
        XCTAssertEqual(recoveredCount, 1)
        let recovered = try XCTUnwrap(manager.failedTranscriptionManager.failedTranscriptions.first)
        XCTAssertTrue(recovered.micAudioURL.path.hasPrefix(retainedAudioDirectory.path + "/"))
        XCTAssertTrue(FileManager.default.fileExists(atPath: recovered.micAudioURL.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: lateCallbackURL.path))

        XCTAssertTrue(manager.promoteFinalizedFailedTranscriptionAudio(
            id: failedID,
            micAudioURL: lateCallbackURL,
            systemAudioURL: nil
        ))

        let afterLateCallback = try XCTUnwrap(manager.failedTranscriptionManager.failedTranscriptions.first)
        XCTAssertEqual(afterLateCallback.micAudioURL, recovered.micAudioURL)
        XCTAssertTrue(FileManager.default.fileExists(atPath: afterLateCallback.micAudioURL.path))
        let reloaded = FailedTranscriptionManager(paths: paths)
        XCTAssertEqual(reloaded.failedTranscriptions.first?.micAudioURL, recovered.micAudioURL)
        XCTAssertTrue(FileManager.default.fileExists(atPath: recovered.micAudioURL.path))
    }

    func testRecoveryRescansFreshTimeoutJournalAfterLivenessWindow() async throws {
        let (manager, paths) = makeManager()
        let primaryURL = paths.audioCaptures.appendingPathComponent("meeting_fresh_mic.wav")
        let recoveryURL = paths.audioCaptures.appendingPathComponent("meeting_fresh_recovery.wav")
        let failedID = UUID()
        try writeMonoWAV(to: primaryURL, sampleRate: 48_000, samples: Array(repeating: 0.3, count: 4_800))
        try writeMonoWAV(to: recoveryURL, sampleRate: 48_000, samples: Array(repeating: 0.6, count: 4_800))
        let journalURL = try writeJournal(
            in: paths.audioCaptures,
            primaryMicFilename: primaryURL.lastPathComponent,
            segments: [
                .init(filename: primaryURL.lastPathComponent, gapBefore: 0),
                .init(filename: recoveryURL.lastPathComponent, gapBefore: 0.1),
            ],
            startedAt: Date(),
            state: .stopping
        )
        XCTAssertTrue(manager.addFailedTranscriptionRetainingAvailableAudio(
            micAudioURL: primaryURL,
            systemAudioURL: nil,
            errorMessage: "Recording stop timed out before audio files were finalized.",
            taskId: failedID,
            archiveAudio: false,
            clearRecordingJournalAfterPersistence: false
        ))

        let recovered = await manager.recoverOrphanedRecordings(
            in: paths.audioCaptures,
            livenessWindow: 0.02,
            waitForRecentJournals: true
        )

        XCTAssertEqual(recovered, 1)
        XCTAssertFalse(FileManager.default.fileExists(atPath: journalURL.path))
        XCTAssertEqual(manager.failedTranscriptionManager.failedTranscriptions.count, 1)
        let entry = try XCTUnwrap(manager.failedTranscriptionManager.failedTranscriptions.first)
        XCTAssertEqual(entry.id, failedID)
        XCTAssertEqual(entry.micAudioURL.lastPathComponent, "meeting_fresh_mic_merged.wav")
    }

    func testRecoveryWaitsThroughRepeatedFreshWrites() async throws {
        let (manager, paths) = makeManager()
        let micURL = paths.audioCaptures.appendingPathComponent("meeting_repeated_write_mic.wav")
        try writeMonoWAV(to: micURL, sampleRate: 48_000, samples: Array(repeating: 0.4, count: 4_800))
        let journalURL = try writeJournal(
            in: paths.audioCaptures,
            primaryMicFilename: micURL.lastPathComponent,
            segments: [.init(filename: micURL.lastPathComponent, gapBefore: 0)],
            startedAt: Date(),
            state: .stopping
        )

        let recoveryTask = Task {
            await manager.recoverOrphanedRecordings(
                in: paths.audioCaptures,
                livenessWindow: 0.08,
                waitForRecentJournals: true
            )
        }
        try await Task.sleep(for: .seconds(0.05))
        try FileManager.default.setAttributes(
            [.modificationDate: Date()],
            ofItemAtPath: micURL.path
        )

        let recovered = await recoveryTask.value

        XCTAssertEqual(recovered, 1)
        XCTAssertFalse(FileManager.default.fileExists(atPath: journalURL.path))
        XCTAssertEqual(manager.failedTranscriptionManager.failedTranscriptions.count, 1)
    }

    func testFutureDatedAudioCannotPinRecoveryOwnerOrBlockLaterJournalScan() async throws {
        let (manager, paths) = makeManager()
        let livenessWindow: TimeInterval = 0.02
        let futureMicURL = paths.audioCaptures.appendingPathComponent("meeting_future_mic.wav")
        try writeMonoWAV(to: futureMicURL, sampleRate: 48_000, samples: Array(repeating: 0.4, count: 4_800))
        try FileManager.default.setAttributes(
            [.modificationDate: Date().addingTimeInterval(1)],
            ofItemAtPath: futureMicURL.path
        )
        let futureJournalURL = try writeJournal(
            in: paths.audioCaptures,
            primaryMicFilename: futureMicURL.lastPathComponent,
            segments: [.init(filename: futureMicURL.lastPathComponent, gapBefore: 0)],
            startedAt: Date(),
            state: .stopping
        )

        var passCount = 0
        var laterJournalURL: URL?
        manager.orphanedRecordingRecoveryPassObserver = { [self] in
            passCount += 1
            guard passCount == 1 else { return }
            do {
                let laterMicURL = paths.audioCaptures.appendingPathComponent("meeting_later_mic.wav")
                try writeMonoWAV(
                    to: laterMicURL,
                    sampleRate: 48_000,
                    samples: Array(repeating: 0.5, count: 4_800)
                )
                try backdate(laterMicURL)
                laterJournalURL = try writeJournal(
                    in: paths.audioCaptures,
                    primaryMicFilename: laterMicURL.lastPathComponent,
                    segments: [.init(filename: laterMicURL.lastPathComponent, gapBefore: 0)],
                    startedAt: Date(timeIntervalSince1970: 1_000),
                    state: .stopping
                )
            } catch {
                XCTFail("Could not create later recovery fixture: \(type(of: error))")
            }
        }

        let recovered = await manager.recoverOrphanedRecordings(
            in: paths.audioCaptures,
            livenessWindow: livenessWindow,
            waitForRecentJournals: true
        )
        manager.orphanedRecordingRecoveryPassObserver = nil

        XCTAssertGreaterThanOrEqual(passCount, 2)
        XCTAssertEqual(recovered, 1)
        XCTAssertEqual(manager.failedTranscriptionManager.failedTranscriptions.count, 1)
        XCTAssertFalse(FileManager.default.fileExists(atPath: try XCTUnwrap(laterJournalURL).path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: futureMicURL.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: futureJournalURL.path))
    }

    func testRecoveryUsesEarliestCandidateRetry() async throws {
        let (manager, paths) = makeManager()
        let livenessWindow: TimeInterval = 0.5
        let olderMicURL = paths.audioCaptures.appendingPathComponent("meeting_older_recent_mic.wav")
        let newerMicURL = paths.audioCaptures.appendingPathComponent("meeting_newer_recent_mic.wav")
        try writeMonoWAV(to: olderMicURL, sampleRate: 48_000, samples: Array(repeating: 0.4, count: 4_800))
        try writeMonoWAV(to: newerMicURL, sampleRate: 48_000, samples: Array(repeating: 0.5, count: 4_800))
        try FileManager.default.setAttributes(
            [.modificationDate: Date().addingTimeInterval(-0.45)],
            ofItemAtPath: olderMicURL.path
        )
        _ = try writeJournal(
            in: paths.audioCaptures,
            primaryMicFilename: olderMicURL.lastPathComponent,
            segments: [.init(filename: olderMicURL.lastPathComponent, gapBefore: 0)],
            startedAt: Date(timeIntervalSince1970: 1_000),
            state: .stopping
        )
        _ = try writeJournal(
            in: paths.audioCaptures,
            primaryMicFilename: newerMicURL.lastPathComponent,
            segments: [.init(filename: newerMicURL.lastPathComponent, gapBefore: 0)],
            startedAt: Date(timeIntervalSince1970: 2_000),
            state: .stopping
        )

        let startedAt = Date()
        var passCount = 0
        var secondPassElapsed: TimeInterval?
        manager.orphanedRecordingRecoveryPassObserver = { [self] in
            passCount += 1
            if passCount == 1 {
                do {
                    try backdate(newerMicURL)
                } catch {
                    XCTFail("Could not age newer recovery fixture: \(type(of: error))")
                }
            } else if passCount == 2 {
                secondPassElapsed = Date().timeIntervalSince(startedAt)
            }
        }

        let recovered = await manager.recoverOrphanedRecordings(
            in: paths.audioCaptures,
            livenessWindow: livenessWindow,
            waitForRecentJournals: true
        )
        manager.orphanedRecordingRecoveryPassObserver = nil

        XCTAssertEqual(recovered, 2)
        XCTAssertGreaterThanOrEqual(passCount, 2)
        XCTAssertLessThan(try XCTUnwrap(secondPassElapsed), 0.3)
    }

    func testJoinedRequestsCannotExtendRecoveryOwnerDeadline() async throws {
        let (manager, paths) = makeManager()
        let livenessWindow: TimeInterval = 0.05
        let futureMicURL = paths.audioCaptures.appendingPathComponent("meeting_joined_future_mic.wav")
        try writeMonoWAV(to: futureMicURL, sampleRate: 48_000, samples: Array(repeating: 0.4, count: 4_800))
        try FileManager.default.setAttributes(
            [.modificationDate: Date().addingTimeInterval(5)],
            ofItemAtPath: futureMicURL.path
        )
        let journalURL = try writeJournal(
            in: paths.audioCaptures,
            primaryMicFilename: futureMicURL.lastPathComponent,
            segments: [.init(filename: futureMicURL.lastPathComponent, gapBefore: 0)],
            startedAt: Date(),
            state: .stopping
        )

        let joinedRequestInjector = Task { @MainActor in
            for _ in 0..<8 {
                do {
                    try await Task.sleep(for: .seconds(0.025))
                } catch {
                    return
                }
                Task { @MainActor in
                    _ = await manager.recoverOrphanedRecordings(
                        in: paths.audioCaptures,
                        livenessWindow: livenessWindow,
                        waitForRecentJournals: true
                    )
                }
            }
        }
        let startedAt = ContinuousClock.now
        let recovered = await manager.recoverOrphanedRecordings(
            in: paths.audioCaptures,
            livenessWindow: livenessWindow,
            waitForRecentJournals: true
        )
        let elapsed = startedAt.duration(to: ContinuousClock.now)
        joinedRequestInjector.cancel()
        await joinedRequestInjector.value

        XCTAssertEqual(recovered, 0)
        XCTAssertLessThan(elapsed, .seconds(0.2))
        XCTAssertTrue(FileManager.default.fileExists(atPath: futureMicURL.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: journalURL.path))
    }

    func testConcurrentRecoveryCallsShareOneJournalOwner() async throws {
        let (manager, paths) = makeManager()
        let micURL = paths.audioCaptures.appendingPathComponent("meeting_single_flight_mic.wav")
        try writeMonoWAV(to: micURL, sampleRate: 48_000, samples: Array(repeating: 0.4, count: 4_800))
        try backdate(micURL)
        let journalURL = try writeJournal(
            in: paths.audioCaptures,
            primaryMicFilename: micURL.lastPathComponent,
            segments: [.init(filename: micURL.lastPathComponent, gapBefore: 0)],
            startedAt: Date(timeIntervalSince1970: 1_000),
            state: .stopping
        )

        async let first = manager.recoverOrphanedRecordings(in: paths.audioCaptures)
        async let second = manager.recoverOrphanedRecordings(in: paths.audioCaptures)
        let results = await [first, second]

        XCTAssertEqual(results, [1, 1])
        XCTAssertFalse(FileManager.default.fileExists(atPath: journalURL.path))
        XCTAssertEqual(manager.failedTranscriptionManager.failedTranscriptions.count, 1)
    }

    func testJoinedRecoveryRequestForcesPassAfterEarlierSnapshot() async throws {
        let (manager, paths) = makeManager()
        var joinedRecoveryTask: Task<Int, Never>?
        manager.orphanedRecordingRecoveryPassObserver = { [self] in
            manager.orphanedRecordingRecoveryPassObserver = nil
            do {
                let micURL = paths.audioCaptures.appendingPathComponent("meeting_joined_request_mic.wav")
                try writeMonoWAV(to: micURL, sampleRate: 48_000, samples: Array(repeating: 0.4, count: 4_800))
                try backdate(micURL)
                _ = try writeJournal(
                    in: paths.audioCaptures,
                    primaryMicFilename: micURL.lastPathComponent,
                    segments: [.init(filename: micURL.lastPathComponent, gapBefore: 0)],
                    startedAt: Date(timeIntervalSince1970: 1_000),
                    state: .stopping
                )
                joinedRecoveryTask = Task {
                    await manager.recoverOrphanedRecordings(
                        in: paths.audioCaptures,
                        livenessWindow: 0,
                        waitForRecentJournals: false
                    )
                }
            } catch {
                XCTFail("Could not create joined recovery fixture: \(type(of: error))")
            }
        }

        let firstResult = await manager.recoverOrphanedRecordings(
            in: paths.audioCaptures,
            livenessWindow: 0,
            waitForRecentJournals: false
        )
        let joinedTask = try XCTUnwrap(joinedRecoveryTask)
        let joinedResult = await joinedTask.value

        XCTAssertEqual(firstResult, 1)
        XCTAssertEqual(joinedResult, 1)
        XCTAssertEqual(manager.failedTranscriptionManager.failedTranscriptions.count, 1)
        XCTAssertTrue(MeetingRecordingJournalStore.journalURLs(in: paths.audioCaptures).isEmpty)
    }

    func testFinalizerOwnershipPreventsRecoveryHandoffAndDuplicateEntry() async throws {
        let (manager, paths) = makeManager()

        let micURL = paths.audioCaptures.appendingPathComponent("meeting_dup_mic.wav")
        try writeMonoWAV(to: micURL, sampleRate: 48_000, samples: Array(repeating: 0.5, count: 4_800))
        try backdate(micURL)

        // Go through a live store so its in-memory journal survives the
        // handoff the way it does in the app process.
        let store = MeetingRecordingJournalStore(directory: paths.audioCaptures)
        let session = store.begin(primaryMicURL: micURL)
        store.markStopping(session: session)
        store.flush()
        let journalURL = paths.audioCaptures.appendingPathComponent(
            "meeting_dup_mic" + MeetingRecordingJournalStore.filenameSuffix
        )
        XCTAssertTrue(FileManager.default.fileExists(atPath: journalURL.path))

        let recoveredWhileFinalizing = await manager.recoverOrphanedRecordings(
            in: paths.audioCaptures,
            livenessWindow: 0,
            waitForRecentJournals: false
        )
        XCTAssertEqual(recoveredWhileFinalizing, 0)
        XCTAssertTrue(manager.failedTranscriptionManager.failedTranscriptions.isEmpty)
        XCTAssertTrue(FileManager.default.fileExists(atPath: journalURL.path))

        // The stop path writes the final state before releasing ownership.
        store.markFinalized(finalMicURL: micURL, session: session)
        store.flush()

        let recovered = await manager.recoverOrphanedRecordings(
            in: paths.audioCaptures,
            livenessWindow: 0,
            waitForRecentJournals: false
        )
        XCTAssertEqual(recovered, 1)
        XCTAssertEqual(manager.failedTranscriptionManager.failedTranscriptions.count, 1)
        XCTAssertFalse(FileManager.default.fileExists(atPath: journalURL.path))

        // A duplicate stale mutation from the ended token cannot resurrect
        // the handed-off journal or create a second failed row.
        store.markFinalized(finalMicURL: micURL, session: session)
        store.flush()
        XCTAssertFalse(FileManager.default.fileExists(atPath: journalURL.path))

        let recoveredAgain = await manager.recoverOrphanedRecordings(in: paths.audioCaptures)
        XCTAssertEqual(recoveredAgain, 0)
        XCTAssertEqual(
            manager.failedTranscriptionManager.failedTranscriptions.count, 1,
            "a resurrected journal would re-recover the same audio into a duplicate failed-queue entry"
        )
    }

    func testRejectsSymlinkedJournalAudioOutsideManagedScratch() async throws {
        let (manager, paths) = makeManager()
        let outsideURL = tempDirectory.appendingPathComponent("outside.wav")
        try writeMonoWAV(to: outsideURL, sampleRate: 48_000, samples: Array(repeating: 0.5, count: 4_800))
        try corruptHeaderSizes(at: outsideURL)
        try backdate(outsideURL)
        let outsideBytes = try Data(contentsOf: outsideURL)

        let symlinkURL = paths.audioCaptures.appendingPathComponent("meeting_symlink_mic.wav")
        try FileManager.default.createSymbolicLink(at: symlinkURL, withDestinationURL: outsideURL)
        let journalURL = try writeJournal(
            in: paths.audioCaptures,
            primaryMicFilename: symlinkURL.lastPathComponent,
            segments: [.init(filename: symlinkURL.lastPathComponent, gapBefore: 0)],
            startedAt: Date(timeIntervalSince1970: 1_000)
        )

        let recovered = await manager.recoverOrphanedRecordings(in: paths.audioCaptures)

        XCTAssertEqual(recovered, 0)
        XCTAssertTrue(manager.failedTranscriptionManager.failedTranscriptions.isEmpty)
        XCTAssertEqual(try Data(contentsOf: outsideURL), outsideBytes)
        XCTAssertTrue(FileManager.default.fileExists(atPath: outsideURL.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: journalURL.path))
    }

    func testRejectsSymlinkedJournalAudioToAnotherManagedRecording() async throws {
        let (manager, paths) = makeManager()
        let otherRecordingURL = paths.audioCaptures.appendingPathComponent("other-recording.wav")
        try writeMonoWAV(
            to: otherRecordingURL,
            sampleRate: 48_000,
            samples: Array(repeating: 0.5, count: 4_800)
        )
        try backdate(otherRecordingURL)
        let originalBytes = try Data(contentsOf: otherRecordingURL)

        let symlinkURL = paths.audioCaptures.appendingPathComponent("meeting_alias_mic.wav")
        try FileManager.default.createSymbolicLink(at: symlinkURL, withDestinationURL: otherRecordingURL)
        let journalURL = try writeJournal(
            in: paths.audioCaptures,
            primaryMicFilename: symlinkURL.lastPathComponent,
            segments: [.init(filename: symlinkURL.lastPathComponent, gapBefore: 0)],
            startedAt: Date(timeIntervalSince1970: 1_000)
        )

        let recovered = await manager.recoverOrphanedRecordings(in: paths.audioCaptures)

        XCTAssertEqual(recovered, 0)
        XCTAssertTrue(manager.failedTranscriptionManager.failedTranscriptions.isEmpty)
        XCTAssertEqual(try Data(contentsOf: otherRecordingURL), originalBytes)
        XCTAssertTrue(FileManager.default.fileExists(atPath: otherRecordingURL.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: journalURL.path))
    }

    func testRejectsRecoveryDirectoryOutsideManagedStorage() async throws {
        let (manager, _) = makeManager()
        let unmanagedDirectory = tempDirectory.appendingPathComponent("unmanaged", isDirectory: true)
        try FileManager.default.createDirectory(at: unmanagedDirectory, withIntermediateDirectories: true)
        let micURL = unmanagedDirectory.appendingPathComponent("meeting_unmanaged_mic.wav")
        try writeMonoWAV(to: micURL, sampleRate: 48_000, samples: Array(repeating: 0.5, count: 4_800))
        try corruptHeaderSizes(at: micURL)
        try backdate(micURL)
        let originalBytes = try Data(contentsOf: micURL)
        let journalURL = try writeJournal(
            in: unmanagedDirectory,
            primaryMicFilename: micURL.lastPathComponent,
            segments: [.init(filename: micURL.lastPathComponent, gapBefore: 0)],
            startedAt: Date(timeIntervalSince1970: 1_000)
        )

        let recovered = await manager.recoverOrphanedRecordings(in: unmanagedDirectory)

        XCTAssertEqual(recovered, 0)
        XCTAssertTrue(manager.failedTranscriptionManager.failedTranscriptions.isEmpty)
        XCTAssertEqual(try Data(contentsOf: micURL), originalBytes)
        XCTAssertTrue(FileManager.default.fileExists(atPath: journalURL.path))
    }

    // MARK: - Fixtures

    private func makeManager(
        retainedAudioDirectory: URL? = nil
    ) -> (TranscriptionTaskManager, CoreStoragePaths) {
        let paths = CoreStoragePaths(
            transcripts: tempDirectory.appendingPathComponent("transcripts"),
            speakerDB: tempDirectory.appendingPathComponent("speakers.sqlite"),
            statsDB: tempDirectory.appendingPathComponent("stats.sqlite"),
            failedQueue: tempDirectory.appendingPathComponent("failed_transcriptions.json"),
            speakerClips: tempDirectory.appendingPathComponent("speaker_clips"),
            audioCaptures: tempDirectory.appendingPathComponent("audio"),
            logs: tempDirectory.appendingPathComponent("logs")
        )
        try? FileManager.default.createDirectory(at: paths.audioCaptures, withIntermediateDirectories: true)
        try? FileManager.default.createDirectory(at: paths.speakerClips, withIntermediateDirectories: true)

        let manager = TranscriptionTaskManager(
            failedTranscriptionManager: FailedTranscriptionManager(paths: paths),
            speechToText: RecoveryStubSpeechToTextEngine(),
            diarization: RecoveryStubDiarizationEngine(),
            speakerStore: SpeakerDatabase(path: paths.speakerDB.path),
            speakerClipsDirectory: paths.speakerClips,
            cleanupDirectories: [paths.audioCaptures, paths.speakerClips],
            retainedAudioDirectory: retainedAudioDirectory
        )
        return (manager, paths)
    }

    private func writeJournal(
        in directory: URL,
        primaryMicFilename: String,
        segments: [MeetingRecordingJournal.SegmentRecord],
        startedAt: Date,
        state: MeetingRecordingJournal.State = .recording,
        systemAudioFilename: String? = nil
    ) throws -> URL {
        let journal = MeetingRecordingJournal(
            version: 1,
            state: state,
            startedAt: startedAt,
            updatedAt: startedAt,
            primaryMicFilename: primaryMicFilename,
            micSegments: segments,
            systemAudioFilename: systemAudioFilename,
            finalMicFilename: nil
        )
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        let stem = (primaryMicFilename as NSString).deletingPathExtension
        let url = directory.appendingPathComponent(stem + MeetingRecordingJournalStore.filenameSuffix)
        try encoder.encode(journal).write(to: url, options: .atomic)
        return url
    }

    private func backdate(_ url: URL) throws {
        try FileManager.default.setAttributes(
            [.modificationDate: Date(timeIntervalSinceNow: -3_600)],
            ofItemAtPath: url.path
        )
    }

    private func corruptHeaderSizes(at url: URL) throws {
        let info = try WAVHeaderRepair.probe(at: url)
        let handle = try FileHandle(forUpdating: url)
        defer { try? handle.close() }
        let headerOnlyRIFFSize = UInt32(info.dataSizeFieldOffset - 4)
        try handle.seek(toOffset: 4)
        try handle.write(contentsOf: withUnsafeBytes(of: headerOnlyRIFFSize.littleEndian) { Data($0) })
        try handle.seek(toOffset: UInt64(info.dataSizeFieldOffset))
        try handle.write(contentsOf: Data([0, 0, 0, 0]))
    }

    private func writeMonoWAV(to url: URL, sampleRate: Double, samples: [Float]) throws {
        let format = try XCTUnwrap(AVAudioFormat(
            commonFormat: .pcmFormatFloat32,
            sampleRate: sampleRate,
            channels: 1,
            interleaved: false
        ))
        let file = try AVAudioFile(
            forWriting: url,
            settings: format.settings,
            commonFormat: format.commonFormat,
            interleaved: format.isInterleaved
        )
        let buffer = try XCTUnwrap(AVAudioPCMBuffer(
            pcmFormat: format,
            frameCapacity: AVAudioFrameCount(samples.count)
        ))
        buffer.frameLength = AVAudioFrameCount(samples.count)
        let channelData = try XCTUnwrap(buffer.floatChannelData?[0])
        samples.withUnsafeBufferPointer { pointer in
            guard let baseAddress = pointer.baseAddress else { return }
            channelData.update(from: baseAddress, count: samples.count)
        }
        try file.write(from: buffer)
        file.close()
    }
}

@available(macOS 14.0, *)
@MainActor
private final class RecoveryStubSpeechToTextEngine: SpeechToTextEngine {
    nonisolated let objectWillChange = ObservableObjectPublisher()
    var isReady = true

    func initialize() async {}
    func transcribeSegment(samples: [Float], source: AudioSource) async throws -> String { "" }
    func cleanup() {}
}

@available(macOS 14.0, *)
@MainActor
private final class RecoveryStubDiarizationEngine: DiarizationEngine {
    nonisolated let objectWillChange = ObservableObjectPublisher()
    var isReady = true

    func initialize() async {}
    func diarizeOffline(samples: [Float], sampleRate: Int) async throws -> [SpeakerSegment] { [] }
    func diarizeOffline(audioURL: URL) async throws -> [SpeakerSegment] { [] }
    func cleanup() {}
}
