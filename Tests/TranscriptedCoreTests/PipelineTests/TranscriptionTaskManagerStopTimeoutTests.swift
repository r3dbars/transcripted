import XCTest
import Combine
import AVFoundation
import FluidAudio
@testable import TranscriptedCore

@available(macOS 14.0, *)
@MainActor
extension TranscriptionTaskManagerMetadataTests {
    func testStopTimeoutFailedQueueCanKeepScratchAudioUntilItFinalizes() throws {
        let retainedAudioDirectory = tempDirectory
            .appendingPathComponent("transcripts", isDirectory: true)
            .appendingPathComponent("audio", isDirectory: true)
        let manager = makeManager(retainedAudioDirectory: retainedAudioDirectory)
        let scratchDirectory = tempDirectory.appendingPathComponent("audio")
        let micURL = scratchDirectory.appendingPathComponent("timeout-mic.wav")
        let systemURL = scratchDirectory.appendingPathComponent("timeout-system.wav")
        try writeMonoWAV(to: micURL, duration: 2.5)
        try writeMonoWAV(to: systemURL, duration: 2.5)

        XCTAssertTrue(manager.addFailedTranscriptionRetainingAvailableAudio(
            micAudioURL: micURL,
            systemAudioURL: systemURL,
            errorMessage: "Recording stop timed out before audio files were finalized.",
            archiveAudio: false
        ))
        let failed = try XCTUnwrap(manager.failedTranscriptionManager.failedTranscriptions.first)

        XCTAssertEqual(failed.micAudioURL, micURL)
        XCTAssertEqual(failed.systemAudioURL, systemURL)
        XCTAssertTrue(FileManager.default.fileExists(atPath: micURL.path), "timeout scratch mic audio should stay in place so late WAV finalization can complete")
        XCTAssertTrue(FileManager.default.fileExists(atPath: systemURL.path), "timeout scratch system audio should stay in place so late WAV finalization can complete")
        XCTAssertFalse(FileManager.default.fileExists(atPath: retainedAudioDirectory.path), "stop-timeout preservation should not copy possibly unfinished WAVs into the retained archive")
    }

    func testLateStopTimeoutFinalizationPromotesFailedQueueAudioToRetainedArchive() throws {
        let retainedAudioDirectory = tempDirectory
            .appendingPathComponent("transcripts", isDirectory: true)
            .appendingPathComponent("audio", isDirectory: true)
        let manager = makeManager(retainedAudioDirectory: retainedAudioDirectory)
        let scratchDirectory = tempDirectory.appendingPathComponent("audio")
        let micURL = scratchDirectory.appendingPathComponent("timeout-final-mic.wav")
        let systemURL = scratchDirectory.appendingPathComponent("timeout-final-system.wav")
        let failedId = UUID()
        try writeMonoWAV(to: micURL, duration: 2.5)
        try writeMonoWAV(to: systemURL, duration: 2.5)

        XCTAssertTrue(manager.addFailedTranscriptionRetainingAvailableAudio(
            micAudioURL: micURL,
            systemAudioURL: systemURL,
            errorMessage: "Recording stop timed out before audio files were finalized.",
            taskId: failedId,
            meetingTitle: "Long Customer Call",
            archiveAudio: false
        ))
        manager.failedTranscriptionManager.incrementRetryCount(id: failedId)

        XCTAssertTrue(manager.promoteFinalizedFailedTranscriptionAudio(
            id: failedId,
            micAudioURL: micURL,
            systemAudioURL: systemURL
        ))

        let failed = try XCTUnwrap(manager.failedTranscriptionManager.failedTranscriptions.first)
        let retainedSystemURL = try XCTUnwrap(failed.systemAudioURL)
        XCTAssertEqual(failed.id, failedId)
        XCTAssertEqual(failed.meetingTitle, "Long Customer Call")
        XCTAssertEqual(failed.retryCount, 1)
        XCTAssertTrue(failed.micAudioURL.path.hasPrefix(retainedAudioDirectory.path + "/"))
        XCTAssertTrue(retainedSystemURL.path.hasPrefix(retainedAudioDirectory.path + "/"))
        XCTAssertTrue(FileManager.default.fileExists(atPath: failed.micAudioURL.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: retainedSystemURL.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: micURL.path), "finalized timeout mic scratch should be removed after archive")
        XCTAssertFalse(FileManager.default.fileExists(atPath: systemURL.path), "finalized timeout system scratch should be removed after archive")

        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let persisted = try decoder.decode(
            [FailedTranscription].self,
            from: Data(contentsOf: tempDirectory.appendingPathComponent("failed_transcriptions.json"))
        )
        XCTAssertEqual(persisted.first?.micAudioURL, failed.micAudioURL)
        XCTAssertEqual(persisted.first?.systemAudioURL, failed.systemAudioURL)
        XCTAssertEqual(persisted.first?.retryCount, 1)
    }

    func testLateStopTimeoutFinalizationKeepsScratchAudioDuringActiveRetry() throws {
        let retainedAudioDirectory = tempDirectory
            .appendingPathComponent("transcripts", isDirectory: true)
            .appendingPathComponent("audio", isDirectory: true)
        let manager = makeManager(retainedAudioDirectory: retainedAudioDirectory)
        let scratchDirectory = tempDirectory.appendingPathComponent("audio")
        let micURL = scratchDirectory.appendingPathComponent("timeout-active-retry-mic.wav")
        let systemURL = scratchDirectory.appendingPathComponent("timeout-active-retry-system.wav")
        let failedId = UUID()
        try writeMonoWAV(to: micURL, duration: 2.5)
        try writeMonoWAV(to: systemURL, duration: 2.5)

        XCTAssertTrue(manager.addFailedTranscriptionRetainingAvailableAudio(
            micAudioURL: micURL,
            systemAudioURL: systemURL,
            errorMessage: "Recording stop timed out before audio files were finalized.",
            taskId: failedId,
            meetingTitle: "Active Retry Call",
            archiveAudio: false
        ))

        let sentinel = Task {}
        manager.activeTasks[failedId] = sentinel
        defer {
            sentinel.cancel()
            manager.activeTasks.removeValue(forKey: failedId)
        }

        XCTAssertTrue(manager.promoteFinalizedFailedTranscriptionAudio(
            id: failedId,
            micAudioURL: micURL,
            systemAudioURL: systemURL
        ))

        let failed = try XCTUnwrap(manager.failedTranscriptionManager.failedTranscriptions.first)
        let retainedSystemURL = try XCTUnwrap(failed.systemAudioURL)
        XCTAssertTrue(failed.micAudioURL.path.hasPrefix(retainedAudioDirectory.path + "/"))
        XCTAssertTrue(retainedSystemURL.path.hasPrefix(retainedAudioDirectory.path + "/"))
        XCTAssertTrue(FileManager.default.fileExists(atPath: failed.micAudioURL.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: retainedSystemURL.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: micURL.path), "active retry may still be reading the original mic scratch")
        XCTAssertTrue(FileManager.default.fileExists(atPath: systemURL.path), "active retry may still be reading the original system scratch")
    }

    func testRetryCompletionRemovesSupersededScratchAudioAfterLatePromotion() async throws {
        let retainedAudioDirectory = tempDirectory
            .appendingPathComponent("transcripts", isDirectory: true)
            .appendingPathComponent("audio", isDirectory: true)
        let speech = BlockingMetadataStubSpeechToTextEngine(transcript: "Recovered after late finalization.")
        let manager = makeManager(
            speechToText: speech,
            retainedAudioDirectory: retainedAudioDirectory
        )
        let scratchDirectory = tempDirectory.appendingPathComponent("audio")
        let micURL = scratchDirectory.appendingPathComponent("timeout-retry-finish-mic.wav")
        let systemURL = scratchDirectory.appendingPathComponent("timeout-retry-finish-system.wav")
        let failedId = UUID()
        try writeMonoWAV(to: micURL, duration: 2.5)
        try writeMonoWAV(to: systemURL, duration: 2.5)

        XCTAssertTrue(manager.addFailedTranscriptionRetainingAvailableAudio(
            micAudioURL: micURL,
            systemAudioURL: systemURL,
            errorMessage: "Recording stop timed out before audio files were finalized.",
            taskId: failedId,
            meetingTitle: "Retry Finish Call",
            archiveAudio: false
        ))

        let retry = Task {
            await manager.retryFailedTranscription(
                failedId: failedId,
                outputFolder: tempDirectory.appendingPathComponent("transcripts")
            )
        }
        try await waitUntil(timeout: 3.0) {
            speech.didStart
        }

        XCTAssertTrue(manager.promoteFinalizedFailedTranscriptionAudio(
            id: failedId,
            micAudioURL: micURL,
            systemAudioURL: systemURL
        ))
        XCTAssertTrue(FileManager.default.fileExists(atPath: micURL.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: systemURL.path))

        speech.release()
        let didRetry = await retry.value

        XCTAssertTrue(didRetry)
        XCTAssertTrue(manager.failedTranscriptionManager.failedTranscriptions.isEmpty)
        XCTAssertFalse(FileManager.default.fileExists(atPath: micURL.path), "finished retry should clean up superseded mic scratch")
        XCTAssertFalse(FileManager.default.fileExists(atPath: systemURL.path), "finished retry should clean up superseded system scratch")
    }

    func testLateStopTimeoutFinalizationPromotesSystemOnlyFailedAudioToRetainedArchive() throws {
        let retainedAudioDirectory = tempDirectory
            .appendingPathComponent("transcripts", isDirectory: true)
            .appendingPathComponent("audio", isDirectory: true)
        let manager = makeManager(retainedAudioDirectory: retainedAudioDirectory)
        let scratchDirectory = tempDirectory.appendingPathComponent("audio")
        let systemURL = scratchDirectory.appendingPathComponent("timeout-final-system.wav")
        let failedId = UUID()
        try writeMonoWAV(to: systemURL, duration: 2.5)

        XCTAssertTrue(manager.addFailedTranscriptionRetainingAvailableAudio(
            micAudioURL: nil,
            systemAudioURL: systemURL,
            errorMessage: "Recording stop timed out before audio files were finalized.",
            taskId: failedId,
            meetingTitle: "System Only Call",
            archiveAudio: false
        ))

        let placeholderMicURL = try XCTUnwrap(manager.failedTranscriptionManager.failedTranscriptions.first?.micAudioURL)
        XCTAssertTrue(placeholderMicURL.lastPathComponent.contains("microphone_placeholder"))
        XCTAssertTrue(FileManager.default.fileExists(atPath: placeholderMicURL.path))

        XCTAssertTrue(manager.promoteFinalizedFailedTranscriptionAudio(
            id: failedId,
            micAudioURL: placeholderMicURL,
            systemAudioURL: systemURL
        ))

        let failed = try XCTUnwrap(manager.failedTranscriptionManager.failedTranscriptions.first)
        let retainedSystemURL = try XCTUnwrap(failed.systemAudioURL)
        XCTAssertEqual(failed.id, failedId)
        XCTAssertEqual(failed.meetingTitle, "System Only Call")
        XCTAssertTrue(failed.micAudioURL.path.hasPrefix(retainedAudioDirectory.path + "/"))
        XCTAssertTrue(retainedSystemURL.path.hasPrefix(retainedAudioDirectory.path + "/"))
        XCTAssertTrue(FileManager.default.fileExists(atPath: failed.micAudioURL.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: retainedSystemURL.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: placeholderMicURL.path), "finalized timeout mic placeholder scratch should be removed after archive")
        XCTAssertFalse(FileManager.default.fileExists(atPath: systemURL.path), "finalized timeout system scratch should be removed after archive")
    }

    func testDeletingOneSystemOnlyTimeoutKeepsOtherRowRetryableAfterReload() throws {
        let manager = makeManager()
        let scratchDirectory = tempDirectory.appendingPathComponent("audio")
        let firstSystemURL = scratchDirectory.appendingPathComponent("first-timeout-system.wav")
        let secondSystemURL = scratchDirectory.appendingPathComponent("second-timeout-system.wav")
        let firstID = UUID()
        let secondID = UUID()
        try writeMonoWAV(to: firstSystemURL, duration: 2.5)
        try writeMonoWAV(to: secondSystemURL, duration: 2.5)

        XCTAssertTrue(manager.addFailedTranscriptionRetainingAvailableAudio(
            micAudioURL: nil,
            systemAudioURL: firstSystemURL,
            errorMessage: "Recording stop timed out before audio files were finalized.",
            taskId: firstID,
            archiveAudio: false
        ))
        XCTAssertTrue(manager.addFailedTranscriptionRetainingAvailableAudio(
            micAudioURL: nil,
            systemAudioURL: secondSystemURL,
            errorMessage: "Recording stop timed out before audio files were finalized.",
            taskId: secondID,
            archiveAudio: false
        ))

        let first = try XCTUnwrap(
            manager.failedTranscriptionManager.failedTranscriptions.first { $0.id == firstID }
        )
        let second = try XCTUnwrap(
            manager.failedTranscriptionManager.failedTranscriptions.first { $0.id == secondID }
        )
        XCTAssertNotEqual(first.micAudioURL, second.micAudioURL)

        XCTAssertTrue(manager.failedTranscriptionManager.deleteFailedTranscription(id: firstID))
        XCTAssertFalse(FileManager.default.fileExists(atPath: first.micAudioURL.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: firstSystemURL.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: second.micAudioURL.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: secondSystemURL.path))

        let reloaded = makeManager()
        let remaining = try XCTUnwrap(reloaded.failedTranscriptionManager.failedTranscriptions.first)
        XCTAssertEqual(reloaded.failedTranscriptionManager.failedTranscriptions.count, 1)
        XCTAssertEqual(remaining.id, secondID)
        XCTAssertEqual(remaining.micAudioURL, second.micAudioURL)
        XCTAssertEqual(remaining.systemAudioURL, secondSystemURL)
        XCTAssertTrue(FileManager.default.fileExists(atPath: remaining.micAudioURL.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: secondSystemURL.path))
    }

    func testLateStopTimeoutFinalizationWithoutRetainedArchiveUpdatesFailedQueueOnly() throws {
        let manager = makeManager()
        let scratchDirectory = tempDirectory.appendingPathComponent("audio")
        let initialMicURL = scratchDirectory.appendingPathComponent("timeout-initial-mic.wav")
        let finalMicURL = scratchDirectory.appendingPathComponent("timeout-final-mic.wav")
        let failedId = UUID()
        try writeMonoWAV(to: initialMicURL, duration: 2.5)
        try writeMonoWAV(to: finalMicURL, duration: 2.5)

        XCTAssertTrue(manager.addFailedTranscriptionRetainingAvailableAudio(
            micAudioURL: initialMicURL,
            systemAudioURL: nil,
            errorMessage: "Recording stop timed out before audio files were finalized.",
            taskId: failedId,
            archiveAudio: false
        ))

        XCTAssertTrue(manager.promoteFinalizedFailedTranscriptionAudio(
            id: failedId,
            micAudioURL: finalMicURL,
            systemAudioURL: nil
        ))

        let failed = try XCTUnwrap(manager.failedTranscriptionManager.failedTranscriptions.first)
        XCTAssertEqual(failed.id, failedId)
        XCTAssertEqual(failed.micAudioURL, finalMicURL)
        XCTAssertNil(failed.systemAudioURL)
        XCTAssertTrue(FileManager.default.fileExists(atPath: initialMicURL.path), "without an archive, promotion should not delete older scratch audio")
        XCTAssertTrue(FileManager.default.fileExists(atPath: finalMicURL.path), "promoted scratch audio should remain available for retry")
    }

    func testLateStopTimeoutFinalizationMissingFailedEntryDoesNotArchiveOrDeleteScratch() throws {
        let retainedAudioDirectory = tempDirectory
            .appendingPathComponent("transcripts", isDirectory: true)
            .appendingPathComponent("audio", isDirectory: true)
        let manager = makeManager(retainedAudioDirectory: retainedAudioDirectory)
        let scratchDirectory = tempDirectory.appendingPathComponent("audio")
        let micURL = scratchDirectory.appendingPathComponent("missing-entry-mic.wav")
        let systemURL = scratchDirectory.appendingPathComponent("missing-entry-system.wav")
        try writeMonoWAV(to: micURL, duration: 2.5)
        try writeMonoWAV(to: systemURL, duration: 2.5)

        XCTAssertFalse(manager.promoteFinalizedFailedTranscriptionAudio(
            id: UUID(),
            micAudioURL: micURL,
            systemAudioURL: systemURL
        ))

        XCTAssertTrue(manager.failedTranscriptionManager.failedTranscriptions.isEmpty)
        XCTAssertTrue(FileManager.default.fileExists(atPath: micURL.path), "missing queue entry should not delete finalized mic scratch")
        XCTAssertTrue(FileManager.default.fileExists(atPath: systemURL.path), "missing queue entry should not delete finalized system scratch")
        XCTAssertFalse(FileManager.default.fileExists(atPath: retainedAudioDirectory.path), "missing queue entry should not create retained audio")
    }

    func testRetryHealsMergedSiblingBeforeRemovingMissingTimeoutRow() async throws {
        let manager = makeManager(
            speechToText: MetadataStubSpeechToTextEngine(transcript: "Recovered finalized meeting.")
        )
        let scratchDirectory = tempDirectory.appendingPathComponent("audio")
        let deletedSegmentURL = scratchDirectory.appendingPathComponent("retry-window-mic.wav")
        let mergedMicURL = scratchDirectory.appendingPathComponent("retry-window-mic_merged.wav")
        let failedId = UUID()
        try writeMonoWAV(to: mergedMicURL, duration: 2.5)

        XCTAssertTrue(manager.addFailedTranscriptionRetainingAvailableAudio(
            micAudioURL: deletedSegmentURL,
            systemAudioURL: nil,
            errorMessage: "Recording stop timed out before audio files were finalized.",
            taskId: failedId,
            meetingTitle: "Finalization Retry Window",
            archiveAudio: false
        ))
        XCTAssertFalse(FileManager.default.fileExists(atPath: deletedSegmentURL.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: mergedMicURL.path))

        let didRetry = await manager.retryFailedTranscription(
            failedId: failedId,
            outputFolder: tempDirectory.appendingPathComponent("transcripts", isDirectory: true)
        )

        XCTAssertTrue(didRetry, "Retry should heal to the safe merged sibling instead of deleting the failed row")
        XCTAssertTrue(manager.failedTranscriptionManager.failedTranscriptions.isEmpty)
        XCTAssertEqual(manager.displayStatus, .transcriptSaved)
        XCTAssertEqual(manager.lastSavedTitle, "Finalization Retry Window")
    }

    func testRetryKeepsTimeoutRowWhenMergedSiblingHealingCannotPersist() async throws {
        let manager = makeManager(
            speechToText: MetadataStubSpeechToTextEngine(transcript: "Recovered finalized meeting.")
        )
        let scratchDirectory = tempDirectory.appendingPathComponent("audio")
        let deletedSegmentURL = scratchDirectory.appendingPathComponent("retry-persist-mic.wav")
        let mergedMicURL = scratchDirectory.appendingPathComponent("retry-persist-mic_merged.wav")
        let failedQueueURL = tempDirectory.appendingPathComponent("failed_transcriptions.json")
        let failedId = UUID()
        try writeMonoWAV(to: mergedMicURL, duration: 2.5)

        XCTAssertTrue(manager.addFailedTranscriptionRetainingAvailableAudio(
            micAudioURL: deletedSegmentURL,
            systemAudioURL: nil,
            errorMessage: "Recording stop timed out before audio files were finalized.",
            taskId: failedId,
            archiveAudio: false
        ))
        try FileManager.default.removeItem(at: failedQueueURL)
        try FileManager.default.createDirectory(at: failedQueueURL, withIntermediateDirectories: true)

        let didRetry = await manager.retryFailedTranscription(
            failedId: failedId,
            outputFolder: tempDirectory.appendingPathComponent("transcripts", isDirectory: true)
        )

        XCTAssertFalse(didRetry)
        XCTAssertEqual(manager.failedTranscriptionManager.failedTranscriptions.map(\.id), [failedId])
        XCTAssertTrue(FileManager.default.fileExists(atPath: mergedMicURL.path))
        XCTAssertEqual(manager.displayStatus, .idle)
    }

    func testRetryKeepsTimeoutRowWhileAudioRootIsUnavailable() async throws {
        let manager = makeManager()
        let scratchDirectory = tempDirectory.appendingPathComponent("audio")
        let unavailableMicURL = scratchDirectory.appendingPathComponent("temporarily-unavailable.wav")
        let failedId = UUID()

        XCTAssertTrue(manager.addFailedTranscriptionRetainingAvailableAudio(
            micAudioURL: unavailableMicURL,
            systemAudioURL: nil,
            errorMessage: "Recording stop timed out before audio files were finalized.",
            taskId: failedId,
            archiveAudio: false
        ))
        try FileManager.default.removeItem(at: scratchDirectory)

        let didRetry = await manager.retryFailedTranscription(
            failedId: failedId,
            outputFolder: tempDirectory.appendingPathComponent("transcripts", isDirectory: true)
        )

        XCTAssertFalse(didRetry)
        XCTAssertEqual(manager.failedTranscriptionManager.failedTranscriptions.map(\.id), [failedId])
        XCTAssertEqual(manager.displayStatus, .idle)
    }

    func testRetryWaitsWhileJournalStillOwnsUnmergedRecoverySegments() async throws {
        let manager = makeManager(
            speechToText: MetadataStubSpeechToTextEngine(transcript: "Should not run yet.")
        )
        let scratchDirectory = tempDirectory.appendingPathComponent("audio")
        let primaryURL = scratchDirectory.appendingPathComponent("journal-owned-mic.wav")
        let recoveryURL = scratchDirectory.appendingPathComponent("journal-owned-recovery.wav")
        let journalURL = scratchDirectory.appendingPathComponent("journal-owned-mic.recording.json")
        try writeMonoWAV(to: primaryURL, duration: 2.5)
        try writeMonoWAV(to: recoveryURL, duration: 2.5)
        let journal = MeetingRecordingJournalStore(directory: scratchDirectory)
        let session = journal.begin(primaryMicURL: primaryURL)
        journal.recordSegments([
            MicRecordingSegment(url: primaryURL),
            MicRecordingSegment(url: recoveryURL, gapBeforeDuration: 0.1),
        ], session: session)
        journal.markStopping(session: session)
        journal.flush()
        let failedID = UUID()
        XCTAssertTrue(manager.addFailedTranscriptionRetainingAvailableAudio(
            micAudioURL: primaryURL,
            systemAudioURL: nil,
            errorMessage: "Recording stop timed out before audio files were finalized.",
            taskId: failedID,
            archiveAudio: false,
            clearRecordingJournalAfterPersistence: false
        ))

        let didRetry = await manager.retryFailedTranscription(
            failedId: failedID,
            outputFolder: tempDirectory.appendingPathComponent("transcripts", isDirectory: true)
        )

        XCTAssertFalse(didRetry)
        XCTAssertEqual(manager.failedTranscriptionManager.failedTranscriptions.map(\.id), [failedID])
        XCTAssertTrue(FileManager.default.fileExists(atPath: primaryURL.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: recoveryURL.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: journalURL.path))
    }

    func testLateStopTimeoutFinalizationRollsBackRetainedArchiveWhenPersistenceFails() throws {
        let retainedAudioDirectory = tempDirectory
            .appendingPathComponent("transcripts", isDirectory: true)
            .appendingPathComponent("audio", isDirectory: true)
        let manager = makeManager(retainedAudioDirectory: retainedAudioDirectory)
        let scratchDirectory = tempDirectory.appendingPathComponent("audio")
        let micURL = scratchDirectory.appendingPathComponent("rollback-mic.wav")
        let systemURL = scratchDirectory.appendingPathComponent("rollback-system.wav")
        let failedQueueURL = tempDirectory.appendingPathComponent("failed_transcriptions.json")
        let failedId = UUID()
        try writeMonoWAV(to: micURL, duration: 2.5)
        try writeMonoWAV(to: systemURL, duration: 2.5)

        XCTAssertTrue(manager.addFailedTranscriptionRetainingAvailableAudio(
            micAudioURL: micURL,
            systemAudioURL: systemURL,
            errorMessage: "Recording stop timed out before audio files were finalized.",
            taskId: failedId,
            archiveAudio: false
        ))
        try FileManager.default.removeItem(at: failedQueueURL)
        try FileManager.default.createDirectory(at: failedQueueURL, withIntermediateDirectories: true)

        XCTAssertFalse(manager.promoteFinalizedFailedTranscriptionAudio(
            id: failedId,
            micAudioURL: micURL,
            systemAudioURL: systemURL
        ))

        let failed = try XCTUnwrap(manager.failedTranscriptionManager.failedTranscriptions.first)
        XCTAssertEqual(failed.micAudioURL, micURL)
        XCTAssertEqual(failed.systemAudioURL, systemURL)
        XCTAssertTrue(FileManager.default.fileExists(atPath: micURL.path), "persistence failure should leave finalized mic scratch in place")
        XCTAssertTrue(FileManager.default.fileExists(atPath: systemURL.path), "persistence failure should leave finalized system scratch in place")
        let retainedChildren = (try? FileManager.default.contentsOfDirectory(
            at: retainedAudioDirectory,
            includingPropertiesForKeys: nil
        )) ?? []
        XCTAssertTrue(retainedChildren.isEmpty, "persistence failure should remove newly retained audio")
    }

    func testLateStopTimeoutFinalizationRejectsUnsafeFinalizedAudioWithoutArchive() throws {
        let manager = makeManager()
        let scratchDirectory = tempDirectory.appendingPathComponent("audio")
        let safeMicURL = scratchDirectory.appendingPathComponent("safe-mic.wav")
        let unsafeMicURL = tempDirectory.appendingPathComponent("unsafe-final-mic.wav")
        let failedId = UUID()
        try writeMonoWAV(to: safeMicURL, duration: 2.5)
        try writeMonoWAV(to: unsafeMicURL, duration: 2.5)

        XCTAssertTrue(manager.addFailedTranscriptionRetainingAvailableAudio(
            micAudioURL: safeMicURL,
            systemAudioURL: nil,
            errorMessage: "Recording stop timed out before audio files were finalized.",
            taskId: failedId,
            archiveAudio: false
        ))

        XCTAssertFalse(manager.promoteFinalizedFailedTranscriptionAudio(
            id: failedId,
            micAudioURL: unsafeMicURL,
            systemAudioURL: nil
        ))

        let failed = try XCTUnwrap(manager.failedTranscriptionManager.failedTranscriptions.first)
        XCTAssertEqual(failed.micAudioURL, safeMicURL)
        XCTAssertTrue(FileManager.default.fileExists(atPath: safeMicURL.path), "unsafe promotion should not delete the original safe mic scratch")
        XCTAssertTrue(FileManager.default.fileExists(atPath: unsafeMicURL.path), "unsafe finalized audio should not be deleted by failed-queue promotion")
    }

    func testTerminalLateFinalizationDiscardRemovesAudioAndJournal() throws {
        let manager = makeManager()
        let scratchDirectory = tempDirectory.appendingPathComponent("audio")
        let micURL = scratchDirectory.appendingPathComponent("terminal-mic_merged.wav")
        let systemURL = scratchDirectory.appendingPathComponent("terminal-system.wav")
        try writeMonoWAV(to: micURL, duration: 2.5)
        try writeMonoWAV(to: systemURL, duration: 2.5)
        let journalURL = scratchDirectory.appendingPathComponent(
            "terminal-mic" + MeetingRecordingJournalStore.filenameSuffix
        )
        let journal = MeetingRecordingJournalStore(directory: scratchDirectory)
        let session = journal.begin(
            primaryMicURL: scratchDirectory.appendingPathComponent("terminal-mic.wav")
        )
        journal.recordSystemAudio(systemURL, session: session)
        journal.markFinalized(finalMicURL: micURL, session: session)
        journal.flush()

        manager.discardFinalizedFailedTranscriptionAudio(
            micAudioURL: micURL,
            systemAudioURL: systemURL
        )

        XCTAssertFalse(FileManager.default.fileExists(atPath: micURL.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: systemURL.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: journalURL.path))
    }

    func testTerminalLateFinalizationDiscardRejectsOutOfCleanupRootJournal() throws {
        let manager = makeManager()
        let outsideDirectory = tempDirectory.appendingPathComponent("outside", isDirectory: true)
        try FileManager.default.createDirectory(at: outsideDirectory, withIntermediateDirectories: true)
        let micURL = outsideDirectory.appendingPathComponent("private-mic.wav")
        let journalURL = outsideDirectory.appendingPathComponent("private-mic.recording.json")
        try Data("private".utf8).write(to: micURL)
        try Data("private".utf8).write(to: journalURL)

        manager.discardFinalizedFailedTranscriptionAudio(
            micAudioURL: micURL,
            systemAudioURL: nil
        )

        XCTAssertTrue(FileManager.default.fileExists(atPath: micURL.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: journalURL.path))
    }

}
