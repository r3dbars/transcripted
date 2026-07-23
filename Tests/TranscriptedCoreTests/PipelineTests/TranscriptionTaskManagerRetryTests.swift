import XCTest
import Combine
import AVFoundation
import FluidAudio
@testable import TranscriptedCore

@available(macOS 14.0, *)
@MainActor
extension TranscriptionTaskManagerMetadataTests {
    func testRetryRejectsReadableAudioAfterDeletionCleanupFailed() async throws {
        let speech = MetadataStubSpeechToTextEngine(transcript: "Must not publish.")
        let manager = makeManager(speechToText: speech)
        let audioDirectory = tempDirectory.appendingPathComponent("audio", isDirectory: true)
        let micURL = audioDirectory.appendingPathComponent("pending-delete-mic.wav")
        let systemURL = audioDirectory.appendingPathComponent("pending-delete-system.wav")
        try writeMonoWAV(to: micURL, duration: 2.5)
        try writeMonoWAV(to: systemURL, duration: 2.5)
        XCTAssertTrue(manager.failedTranscriptionManager.addFailedTranscription(
            micAudioURL: micURL,
            systemAudioURL: systemURL,
            errorMessage: "Original failure"
        ))
        let failedID = try XCTUnwrap(manager.failedTranscriptionManager.failedTranscriptions.first?.id)

        defer {
            try? FileManager.default.setAttributes(
                [.posixPermissions: 0o700],
                ofItemAtPath: audioDirectory.path
            )
        }
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o500],
            ofItemAtPath: audioDirectory.path
        )
        XCTAssertFalse(manager.failedTranscriptionManager.deleteFailedTranscription(id: failedID))
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o700],
            ofItemAtPath: audioDirectory.path
        )
        XCTAssertTrue(FileManager.default.fileExists(atPath: micURL.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: systemURL.path))

        let didRetry = await manager.retryFailedTranscription(
            failedId: failedID,
            outputFolder: tempDirectory.appendingPathComponent("transcripts", isDirectory: true)
        )

        XCTAssertFalse(didRetry)
        XCTAssertEqual(manager.failedTranscriptionManager.failedTranscriptions.map(\.id), [failedID])
        XCTAssertNil(manager.lastSavedTranscriptURL)
    }

    func testRetryFailedTranscriptionSuccessCreatesMarkdownAndClearsFailedQueue() async throws {
        let manager = makeManager(
            speechToText: MetadataStubSpeechToTextEngine(transcript: "Recovered meeting artifact.")
        )
        let audioDirectory = tempDirectory.appendingPathComponent("audio", isDirectory: true)
        let micURL = audioDirectory.appendingPathComponent("retry-mic.wav")
        let systemURL = audioDirectory.appendingPathComponent("retry-system.wav")
        try writeMonoWAV(to: micURL, duration: 2.5)
        try writeMonoWAV(to: systemURL, duration: 2.5)

        XCTAssertTrue(manager.failedTranscriptionManager.addFailedTranscription(
            micAudioURL: micURL,
            systemAudioURL: systemURL,
            errorMessage: PipelineError.modelInferenceFailed(model: "Parakeet", underlying: "temporary").localizedDescription,
            meetingTitle: "Recovered Customer Call"
        ))
        let failed = try XCTUnwrap(manager.failedTranscriptionManager.failedTranscriptions.first)

        let didRetry = await manager.retryFailedTranscription(
            failedId: failed.id,
            outputFolder: tempDirectory.appendingPathComponent("transcripts", isDirectory: true)
        )

        XCTAssertTrue(didRetry)
        XCTAssertTrue(manager.failedTranscriptionManager.failedTranscriptions.isEmpty)
        XCTAssertEqual(manager.displayStatus, .transcriptSaved)

        let transcriptURL = try XCTUnwrap(manager.lastSavedTranscriptURL)
        XCTAssertTrue(FileManager.default.fileExists(atPath: transcriptURL.path))
        let markdown = try String(contentsOf: transcriptURL, encoding: .utf8)
        XCTAssertTrue(markdown.contains("Recovered Customer Call"))
        XCTAssertTrue(markdown.contains("Recovered meeting artifact."))
    }

    func testRetryFailedTranscriptionSupportsMicOnlyRecoveredAudio() async throws {
        let manager = makeManager(
            speechToText: MetadataStubSpeechToTextEngine(transcript: "Recovered from mic only.")
        )
        let audioDirectory = tempDirectory.appendingPathComponent("audio", isDirectory: true)
        let micURL = audioDirectory.appendingPathComponent("retry-mic-only.wav")
        try writeMonoWAV(to: micURL, duration: 2.5)

        XCTAssertTrue(manager.failedTranscriptionManager.addFailedTranscription(
            micAudioURL: micURL,
            systemAudioURL: nil,
            errorMessage: "Recording was interrupted before it could be saved. The recovered audio is ready to transcribe.",
            meetingTitle: "Mic-only recovered call"
        ))
        let failed = try XCTUnwrap(manager.failedTranscriptionManager.failedTranscriptions.first)
        XCTAssertTrue(failed.isRetryable)

        let didRetry = await manager.retryFailedTranscription(
            failedId: failed.id,
            outputFolder: tempDirectory.appendingPathComponent("transcripts", isDirectory: true)
        )

        XCTAssertTrue(didRetry)
        XCTAssertTrue(manager.failedTranscriptionManager.failedTranscriptions.isEmpty)
        let transcriptURL = try XCTUnwrap(manager.lastSavedTranscriptURL)
        let markdown = try String(contentsOf: transcriptURL, encoding: .utf8)
        XCTAssertTrue(markdown.contains("sources: [mic]"))
        XCTAssertTrue(markdown.contains("system_audio_missing: true"))
        XCTAssertTrue(markdown.contains("Recovered from mic only."))
    }

    func testCancelAllDuringRetryDoesNotPoisonFutureRetry() async throws {
        let speech = BlockingMetadataStubSpeechToTextEngine(transcript: "Recovered after cancel.")
        let manager = makeManager(speechToText: speech)
        let audioDirectory = tempDirectory.appendingPathComponent("audio", isDirectory: true)
        let micURL = audioDirectory.appendingPathComponent("retry-cancel-mic.wav")
        let systemURL = audioDirectory.appendingPathComponent("retry-cancel-system.wav")
        let outputFolder = tempDirectory.appendingPathComponent("transcripts", isDirectory: true)
        try writeMonoWAV(to: micURL, duration: 2.5)
        try writeMonoWAV(to: systemURL, duration: 2.5)

        XCTAssertTrue(manager.failedTranscriptionManager.addFailedTranscription(
            micAudioURL: micURL,
            systemAudioURL: systemURL,
            errorMessage: "Original failure",
            meetingTitle: "Retry cancel"
        ))
        let failedId = try XCTUnwrap(manager.failedTranscriptionManager.failedTranscriptions.first?.id)

        let cancelledRetry = Task {
            await manager.retryFailedTranscription(
                failedId: failedId,
                outputFolder: outputFolder
            )
        }

        try await waitUntil {
            speech.didStart
        }

        manager.cancelAll()
        speech.release()

        let didCancelledRetrySucceed = await cancelledRetry.value
        XCTAssertFalse(didCancelledRetrySucceed)
        XCTAssertEqual(manager.failedTranscriptionManager.failedTranscriptions.map(\.id), [failedId])
        XCTAssertNil(manager.lastSavedTranscriptURL)

        let didRetry = await manager.retryFailedTranscription(
            failedId: failedId,
            outputFolder: outputFolder
        )

        XCTAssertTrue(didRetry, "a cancelled retry should not leave the failed id marked cancelled forever")
        XCTAssertTrue(manager.failedTranscriptionManager.failedTranscriptions.isEmpty)
        let transcriptURL = try XCTUnwrap(manager.lastSavedTranscriptURL)
        let markdown = try String(contentsOf: transcriptURL, encoding: .utf8)
        XCTAssertTrue(markdown.contains("Recovered after cancel."))
    }

    func testCancelAllDuringRetryCancelsInFlightInference() async throws {
        let speech = BlockingMetadataStubSpeechToTextEngine(transcript: "Never finishes.")
        let manager = makeManager(speechToText: speech)
        let audioDirectory = tempDirectory.appendingPathComponent("audio", isDirectory: true)
        let micURL = audioDirectory.appendingPathComponent("retry-inflight-mic.wav")
        let systemURL = audioDirectory.appendingPathComponent("retry-inflight-system.wav")
        let outputFolder = tempDirectory.appendingPathComponent("transcripts", isDirectory: true)
        try writeMonoWAV(to: micURL, duration: 2.5)
        try writeMonoWAV(to: systemURL, duration: 2.5)

        XCTAssertTrue(manager.failedTranscriptionManager.addFailedTranscription(
            micAudioURL: micURL,
            systemAudioURL: systemURL,
            errorMessage: "Original failure",
            meetingTitle: "Retry in-flight cancel"
        ))
        let failedId = try XCTUnwrap(manager.failedTranscriptionManager.failedTranscriptions.first?.id)

        let retry = Task {
            await manager.retryFailedTranscription(
                failedId: failedId,
                outputFolder: outputFolder
            )
        }

        try await waitUntil {
            speech.didStart
        }
        XCTAssertNotNil(manager.activeTasks[failedId], "retry must register its work in activeTasks")
        XCTAssertTrue(
            manager.hasActiveTranscriptionWorkRequiringQuitConfirmation,
            "an in-flight failed-meeting retry should keep the background-work quit warning enabled"
        )

        manager.cancelAll()
        XCTAssertFalse(
            manager.hasActiveTranscriptionWorkRequiringQuitConfirmation,
            "cancelled retry occupancy should no longer require a quit warning"
        )

        // No release(): the only way the blocked engine can unwind is real task
        // cancellation reaching the in-flight inference.
        let didRetry = await retry.value

        XCTAssertFalse(didRetry)
        XCTAssertTrue(speech.sawCancellation, "cancelAll must cancel the retry's in-flight inference")
        XCTAssertFalse(speech.didReturn)
        XCTAssertTrue(manager.activeTasks.isEmpty)
    }

    func testRetrySuccessWithoutSpeakerNamingDeletesRetainedFailedAudio() async throws {
        let retainedAudioDirectory = tempDirectory
            .appendingPathComponent("transcripts", isDirectory: true)
            .appendingPathComponent("audio", isDirectory: true)
        let manager = makeManager(
            speechToText: MetadataStubSpeechToTextEngine(transcript: "Recovered meeting artifact."),
            retainedAudioDirectory: retainedAudioDirectory
        )
        let scratchDirectory = tempDirectory.appendingPathComponent("audio")
        let micURL = scratchDirectory.appendingPathComponent("retry-retained-mic.wav")
        let systemURL = scratchDirectory.appendingPathComponent("retry-retained-system.wav")
        try writeMonoWAV(to: micURL, duration: 2.5)
        try writeMonoWAV(to: systemURL, duration: 2.5)

        XCTAssertTrue(manager.addFailedTranscriptionRetainingAvailableAudio(
            micAudioURL: micURL,
            systemAudioURL: systemURL,
            errorMessage: "Parakeet inference failed",
            meetingTitle: "Recovered Customer Call"
        ))
        let failed = try XCTUnwrap(manager.failedTranscriptionManager.failedTranscriptions.first)
        let retainedMicURL = failed.micAudioURL
        let retainedSystemURL = try XCTUnwrap(failed.systemAudioURL)
        let retainedDirectory = retainedMicURL.deletingLastPathComponent()
        XCTAssertTrue(retainedMicURL.path.hasPrefix(retainedAudioDirectory.path + "/"))
        XCTAssertTrue(retainedSystemURL.path.hasPrefix(retainedAudioDirectory.path + "/"))

        let didRetry = await manager.retryFailedTranscription(
            failedId: failed.id,
            outputFolder: tempDirectory.appendingPathComponent("transcripts", isDirectory: true)
        )

        XCTAssertTrue(didRetry)
        XCTAssertTrue(manager.failedTranscriptionManager.failedTranscriptions.isEmpty)
        XCTAssertNil(manager.speakerNamingRequest)
        XCTAssertFalse(FileManager.default.fileExists(atPath: retainedMicURL.path), "successful retry should delete retained failed mic audio")
        XCTAssertFalse(FileManager.default.fileExists(atPath: retainedSystemURL.path), "successful retry should delete retained failed system audio")
        XCTAssertFalse(FileManager.default.fileExists(atPath: retainedDirectory.path), "successful retry should remove the now-empty retained audio directory")
    }

    func testRetryDeletesRetainedFailedAudioWhenSpeakerNameFinalizationSucceeds() async throws {
        let speech = MetadataStubSpeechToTextEngine(transcript: "Thanks for joining.")
        let diarization = MetadataStubDiarizationEngine(segments: [
            SpeakerSegment(
                speakerId: 1,
                startTime: 0,
                endTime: 2,
                embedding: [Float](repeating: 0.42, count: 256),
                qualityScore: 0.95
            )
        ])
        let retainedAudioDirectory = tempDirectory
            .appendingPathComponent("transcripts", isDirectory: true)
            .appendingPathComponent("audio", isDirectory: true)
        let manager = makeManager(
            speechToText: speech,
            diarization: diarization,
            retainedAudioDirectory: retainedAudioDirectory
        )
        let scratchDirectory = tempDirectory.appendingPathComponent("audio")
        let micURL = scratchDirectory.appendingPathComponent("retry-mic.wav")
        let systemURL = scratchDirectory.appendingPathComponent("retry-system.wav")
        try writeMonoWAV(to: micURL, duration: 2.5)
        try writeMonoWAV(to: systemURL, duration: 2.5)

        XCTAssertTrue(manager.addFailedTranscriptionRetainingAvailableAudio(
            micAudioURL: micURL,
            systemAudioURL: systemURL,
            errorMessage: "Parakeet inference failed"
        ))
        let failed = try XCTUnwrap(manager.failedTranscriptionManager.failedTranscriptions.first)
        let failedId = failed.id
        let retainedMicURL = failed.micAudioURL
        let retainedSystemURL = try XCTUnwrap(failed.systemAudioURL)
        let retainedDirectory = retainedMicURL.deletingLastPathComponent()
        XCTAssertTrue(retainedMicURL.path.hasPrefix(retainedAudioDirectory.path + "/"))
        XCTAssertTrue(retainedSystemURL.path.hasPrefix(retainedAudioDirectory.path + "/"))
        XCTAssertFalse(FileManager.default.fileExists(atPath: micURL.path), "scratch mic audio should move into the retained failed-audio archive")
        XCTAssertFalse(FileManager.default.fileExists(atPath: systemURL.path), "scratch system audio should move into the retained failed-audio archive")

        let didRetry = await manager.retryFailedTranscription(
            failedId: failedId,
            outputFolder: tempDirectory.appendingPathComponent("transcripts")
        )

        XCTAssertTrue(didRetry)
        let request = try XCTUnwrap(manager.speakerNamingRequest)
        let speaker = try XCTUnwrap(request.speakers.first)
        request.onComplete([
            SpeakerNameUpdate(
                persistentSpeakerId: speaker.id,
                diarizerSpeakerId: speaker.diarizerSpeakerId,
                channel: speaker.channel,
                newName: "Sarah Graham",
                previousName: speaker.currentName,
                action: .named
            )
        ])

        try await waitUntil {
            manager.failedTranscriptionManager.failedTranscriptions.isEmpty
                && manager.speakerNamingRequest == nil
        }
        XCTAssertFalse(FileManager.default.fileExists(atPath: retainedMicURL.path), "successful failed-meeting retry should delete retained mic audio")
        XCTAssertFalse(FileManager.default.fileExists(atPath: retainedSystemURL.path), "successful failed-meeting retry should delete retained system audio")
        XCTAssertFalse(FileManager.default.fileExists(atPath: retainedDirectory.path), "successful failed-meeting retry should remove the now-empty retained audio directory")
    }

    func testRetryFailedTranscriptionUsesOriginalRecordingDateForSavedMetadata() async throws {
        let recordingDate = localDate(
            year: 2026,
            month: 6,
            day: 5,
            hour: 11,
            minute: 43,
            second: 12
        )
        let statsStore = MetadataCapturingStatsStore()
        let manager = makeManager(
            speechToText: MetadataStubSpeechToTextEngine(transcript: "Recovered meeting artifact."),
            diarization: MetadataStubDiarizationEngine(segments: [
                SpeakerSegment(
                    speakerId: 1,
                    startTime: 0,
                    endTime: 2,
                    embedding: [Float](repeating: 0.42, count: 256),
                    qualityScore: 0.95
                )
            ]),
            statsStore: statsStore
        )
        let scratchDirectory = tempDirectory.appendingPathComponent("audio")
        let micURL = scratchDirectory.appendingPathComponent("failed-date-mic.wav")
        let systemURL = scratchDirectory.appendingPathComponent("failed-date-system.wav")
        try writeMonoWAV(to: micURL, duration: 2.5)
        try writeMonoWAV(to: systemURL, duration: 2.5)
        XCTAssertTrue(manager.failedTranscriptionManager.addFailedTranscription(
            micAudioURL: micURL,
            systemAudioURL: systemURL,
            errorMessage: "Parakeet inference failed",
            meetingTitle: "Recovered customer call",
            recordingDate: recordingDate
        ))
        let failedId = try XCTUnwrap(manager.failedTranscriptionManager.failedTranscriptions.first?.id)

        let didRetry = await manager.retryFailedTranscription(
            failedId: failedId,
            outputFolder: tempDirectory.appendingPathComponent("transcripts")
        )

        XCTAssertTrue(didRetry)
        try await waitUntil {
            manager.lastSavedTranscriptURL != nil && manager.activeTasks.isEmpty
        }
        let transcriptURL = try XCTUnwrap(manager.lastSavedTranscriptURL)
        let markdown = try String(contentsOf: transcriptURL, encoding: .utf8)
        XCTAssertTrue(
            transcriptURL.lastPathComponent.hasPrefix("Call_\(DateFormattingHelper.formatFilename(recordingDate))"),
            "failed meeting retry filenames should use the original recording date"
        )
        XCTAssertTrue(markdown.contains("\ndate: \(frontmatterDateString(recordingDate))\n"))
        XCTAssertTrue(markdown.contains("\ntime: \(frontmatterTimeString(recordingDate))\n"))
        let metadata = try XCTUnwrap(statsStore.recordedSessions.first)
        XCTAssertLessThan(
            abs(metadata.date.timeIntervalSince(recordingDate)),
            0.001,
            "retry stats metadata should use the original recording date"
        )
    }

    func testRetryKeepsFailedAudioWhenSpeakerNameFinalizationSucceedsAfterArchiveFailure() async throws {
        let speech = MetadataStubSpeechToTextEngine(transcript: "Thanks for joining.")
        let diarization = MetadataStubDiarizationEngine(segments: [
            SpeakerSegment(
                speakerId: 1,
                startTime: 0,
                endTime: 2,
                embedding: [Float](repeating: 0.42, count: 256),
                qualityScore: 0.95
            )
        ])
        let archiveBlockerURL = tempDirectory.appendingPathComponent("audio-archive-blocker")
        try Data("not a directory".utf8).write(to: archiveBlockerURL)
        let manager = makeManager(
            speechToText: speech,
            diarization: diarization,
            retainedAudioDirectoryProvider: { archiveBlockerURL }
        )
        let scratchDirectory = tempDirectory.appendingPathComponent("audio")
        let micURL = scratchDirectory.appendingPathComponent("retry-mic.wav")
        let systemURL = scratchDirectory.appendingPathComponent("retry-system.wav")
        try writeMonoWAV(to: micURL, duration: 2.5)
        try writeMonoWAV(to: systemURL, duration: 2.5)

        XCTAssertTrue(manager.failedTranscriptionManager.addFailedTranscription(
            micAudioURL: micURL,
            systemAudioURL: systemURL,
            errorMessage: "Parakeet inference failed"
        ))
        let failedId = try XCTUnwrap(manager.failedTranscriptionManager.failedTranscriptions.first?.id)

        let didRetry = await manager.retryFailedTranscription(
            failedId: failedId,
            outputFolder: tempDirectory.appendingPathComponent("transcripts")
        )

        XCTAssertTrue(didRetry)
        let request = try XCTUnwrap(manager.speakerNamingRequest)
        let speaker = try XCTUnwrap(request.speakers.first)
        request.onComplete([
            SpeakerNameUpdate(
                persistentSpeakerId: speaker.id,
                diarizerSpeakerId: speaker.diarizerSpeakerId,
                channel: speaker.channel,
                newName: "Sarah Graham",
                previousName: speaker.currentName,
                action: .named
            )
        ])

        try await waitUntil {
            manager.failedTranscriptionManager.failedTranscriptions.isEmpty
                && manager.speakerNamingRequest == nil
        }
        XCTAssertTrue(FileManager.default.fileExists(atPath: micURL.path), "archive failure should leave the failed mic audio on disk")
        XCTAssertTrue(FileManager.default.fileExists(atPath: systemURL.path), "archive failure should leave the failed system audio on disk")
    }

    func testRetryKeepsFailedMeetingWhenSpeakerNameFinalizationFails() async throws {
        let speech = MetadataStubSpeechToTextEngine(transcript: "Thanks for joining.")
        let diarization = MetadataStubDiarizationEngine(segments: [
            SpeakerSegment(
                speakerId: 1,
                startTime: 0,
                endTime: 2,
                embedding: [Float](repeating: 0.42, count: 256),
                qualityScore: 0.95
            )
        ])
        let retainedAudioDirectory = tempDirectory
            .appendingPathComponent("transcripts", isDirectory: true)
            .appendingPathComponent("audio", isDirectory: true)
        let manager = makeManager(
            speechToText: speech,
            diarization: diarization,
            retainedAudioDirectory: retainedAudioDirectory
        )
        let scratchDirectory = tempDirectory.appendingPathComponent("audio")
        let micURL = scratchDirectory.appendingPathComponent("retry-mic.wav")
        let systemURL = scratchDirectory.appendingPathComponent("retry-system.wav")
        try writeMonoWAV(to: micURL, duration: 2.5)
        try writeMonoWAV(to: systemURL, duration: 2.5)

        XCTAssertTrue(manager.failedTranscriptionManager.addFailedTranscription(
            micAudioURL: micURL,
            systemAudioURL: systemURL,
            errorMessage: "Parakeet inference failed"
        ))
        let failedId = try XCTUnwrap(manager.failedTranscriptionManager.failedTranscriptions.first?.id)

        let didRetry = await manager.retryFailedTranscription(
            failedId: failedId,
            outputFolder: tempDirectory.appendingPathComponent("transcripts")
        )

        XCTAssertTrue(didRetry)
        let request = try XCTUnwrap(manager.speakerNamingRequest)
        XCTAssertEqual(request.sourceFailedTranscriptionId, failedId)
        XCTAssertFalse(
            request.shouldRemoveTemporaryAudioOnCleanup,
            "failed-retry speaker review must not own cleanup for audio that keeps the failed row retryable"
        )
        XCTAssertEqual(
            manager.failedTranscriptionManager.failedTranscriptions.map(\.id),
            [failedId],
            "retry should stay visible until speaker-name finalization succeeds"
        )
        XCTAssertTrue(manager.failedTranscriptionManager.failedTranscriptions[0].audioFilesExist())

        try FileManager.default.removeItem(at: request.transcriptURL)
        let speaker = try XCTUnwrap(request.speakers.first)
        request.onComplete([
            SpeakerNameUpdate(
                persistentSpeakerId: speaker.id,
                diarizerSpeakerId: speaker.diarizerSpeakerId,
                channel: speaker.channel,
                newName: "Sarah Graham",
                previousName: speaker.currentName,
                action: .named
            )
        ])

        try await waitUntil {
            if case .failed(message: "Failed to finalize speaker names") = manager.displayStatus,
               manager.speakerNamingRequest == nil {
                return true
            }
            return false
        }

        let failed = try XCTUnwrap(manager.failedTranscriptionManager.failedTranscriptions.first)
        XCTAssertEqual(failed.id, failedId)
        XCTAssertTrue(failed.errorMessage.contains("Speaker names could not be saved"))
        XCTAssertTrue(failed.audioFilesExist(), "failed retry audio should remain available for another pass")
    }

    func testRetryFailureUpdatesPersistedFailedMeetingError() async throws {
        let speech = MetadataStubSpeechToTextEngine(
            transcribeError: PipelineError.modelInferenceFailed(model: "Parakeet", underlying: "boom")
        )
        let manager = makeManager(speechToText: speech)
        let scratchDirectory = tempDirectory.appendingPathComponent("audio")
        let micURL = scratchDirectory.appendingPathComponent("retry-mic.wav")
        let systemURL = scratchDirectory.appendingPathComponent("retry-system.wav")
        try writeMonoWAV(to: micURL, duration: 2.5)
        try writeMonoWAV(to: systemURL, duration: 2.5)

        XCTAssertTrue(manager.failedTranscriptionManager.addFailedTranscription(
            micAudioURL: micURL,
            systemAudioURL: systemURL,
            errorMessage: "Original failure",
            meetingTitle: "Customer call"
        ))
        let failedId = try XCTUnwrap(manager.failedTranscriptionManager.failedTranscriptions.first?.id)

        let didRetry = await manager.retryFailedTranscription(
            failedId: failedId,
            outputFolder: tempDirectory.appendingPathComponent("transcripts")
        )

        XCTAssertFalse(didRetry)
        let failed = try XCTUnwrap(manager.failedTranscriptionManager.failedTranscriptions.first)
        XCTAssertEqual(failed.id, failedId)
        XCTAssertEqual(failed.meetingTitle, "Customer call")
        XCTAssertEqual(failed.errorMessage, "Retry failed: Parakeet inference failed")
    }

}
