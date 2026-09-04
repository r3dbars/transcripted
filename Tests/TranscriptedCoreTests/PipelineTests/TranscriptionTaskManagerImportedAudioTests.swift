import XCTest
import Combine
import AVFoundation
import FluidAudio
@testable import TranscriptedCore

private final class ImportedRecoverySessionSpy: ImportedTranscriptionRecoverySession, @unchecked Sendable {
    let jobID: UUID

    private let lock = NSLock()
    private var transcriptCommits = 0
    private var scratchCleanupPreparations = 0
    private var scratchCleanups = 0
    private var failedQueueHandoffs = 0
    private var finished = false

    init(jobID: UUID) {
        self.jobID = jobID
    }

    var transcriptCommitCount: Int { lock.withLock { transcriptCommits } }
    var scratchCleanupPreparationCount: Int { lock.withLock { scratchCleanupPreparations } }
    var scratchCleanupCount: Int { lock.withLock { scratchCleanups } }
    var failedQueueHandoffCount: Int { lock.withLock { failedQueueHandoffs } }

    func transcriptCommitConfirmed() {
        lock.withLock { transcriptCommits += 1 }
    }

    func prepareForScratchCleanup() -> Bool {
        lock.withLock {
            guard !finished else { return false }
            scratchCleanupPreparations += 1
            return true
        }
    }

    func scratchCleanupConfirmed() {
        lock.withLock {
            scratchCleanups += 1
            finished = true
        }
    }

    func failedQueueHandoffConfirmed() {
        lock.withLock {
            failedQueueHandoffs += 1
            finished = true
        }
    }
}

@available(macOS 14.0, *)
@MainActor
extension TranscriptionTaskManagerMetadataTests {
    func testStartImportedTranscriptionDoesNotDeleteOutOfSandboxFileWhenRejected() throws {
        let manager = makeManager()
        let externalURL = tempDirectory.appendingPathComponent("outside.wav")
        try writeMonoWAV(to: externalURL, duration: 2.5)

        manager.activeTasks[UUID()] = Task {}
        manager.startImportedTranscription(
            audioURL: externalURL,
            outputFolder: tempDirectory.appendingPathComponent("transcripts")
        )

        XCTAssertTrue(FileManager.default.fileExists(atPath: externalURL.path))
    }

    func testPreserveActiveTranscriptionsForShutdownRetainsImportedAudio() async throws {
        let speech = BlockingMetadataStubSpeechToTextEngine(transcript: "Imported shutdown recovery.")
        let retainedAudioDirectory = tempDirectory
            .appendingPathComponent("transcripts", isDirectory: true)
            .appendingPathComponent("audio", isDirectory: true)
        let manager = makeManager(
            speechToText: speech,
            diarization: MetadataStubDiarizationEngine(segments: singleSpeakerSegments()),
            retainedAudioDirectory: retainedAudioDirectory
        )
        let copiedImportURL = tempDirectory
            .appendingPathComponent("audio", isDirectory: true)
            .appendingPathComponent("imported-meeting.wav")
        try writeMonoWAV(to: copiedImportURL, duration: 2.5)
        let taskId = UUID()
        let recoverySession = ImportedRecoverySessionSpy(jobID: taskId)

        manager.startImportedTranscription(
            taskId: taskId,
            audioURL: copiedImportURL,
            outputFolder: tempDirectory.appendingPathComponent("transcripts"),
            meetingTitle: "Imported customer call",
            recoverySession: recoverySession
        )

        try await waitUntil {
            speech.didStart
        }

        let preserved = manager.preserveActiveTranscriptionsForShutdown(
            errorMessage: "Meeting saved before quit. Audio is safe; finish the transcript from Home after reopening."
        )

        XCTAssertEqual(preserved, 1)
        XCTAssertTrue(manager.activeTasks.isEmpty)
        XCTAssertEqual(manager.activeCount, 0)
        let failed = try XCTUnwrap(manager.failedTranscriptionManager.failedTranscriptions.first)
        XCTAssertEqual(failed.meetingTitle, "Imported customer call")
        XCTAssertFalse(failed.splitLocalSpeakers)
        XCTAssertTrue(failed.micAudioURL.lastPathComponent.hasPrefix("microphone_placeholder"))
        XCTAssertTrue(failed.micAudioURL.path.hasPrefix(retainedAudioDirectory.path + "/"))
        XCTAssertTrue(failed.systemAudioURL?.path.hasPrefix(retainedAudioDirectory.path + "/") ?? false)
        XCTAssertTrue(FileManager.default.fileExists(atPath: failed.micAudioURL.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: failed.systemAudioURL?.path ?? ""))
        XCTAssertFalse(FileManager.default.fileExists(atPath: copiedImportURL.path))
        XCTAssertEqual(recoverySession.failedQueueHandoffCount, 1)
        XCTAssertEqual(recoverySession.scratchCleanupCount, 0)

        speech.release()
    }

    func testShutdownPreservesActiveImportedAudioBeforePendingNamingCleanup() async throws {
        let speech = BlockingMetadataStubSpeechToTextEngine(transcript: "Imported shutdown ordering.")
        let retainedAudioDirectory = tempDirectory
            .appendingPathComponent("transcripts", isDirectory: true)
            .appendingPathComponent("audio", isDirectory: true)
        let manager = makeManager(
            speechToText: speech,
            diarization: MetadataStubDiarizationEngine(segments: singleSpeakerSegments()),
            retainedAudioDirectory: retainedAudioDirectory
        )
        let copiedImportURL = tempDirectory
            .appendingPathComponent("audio", isDirectory: true)
            .appendingPathComponent("imported-precommit-review.wav")
        try writeMonoWAV(to: copiedImportURL, duration: 2.5)
        let taskId = UUID()
        let recoverySession = ImportedRecoverySessionSpy(jobID: taskId)

        manager.startImportedTranscription(
            taskId: taskId,
            audioURL: copiedImportURL,
            outputFolder: tempDirectory.appendingPathComponent("transcripts"),
            recoverySession: recoverySession
        )
        try await waitUntil { speech.didStart }

        manager.speakerNamingRequest = SpeakerNamingRequest(
            speakers: [],
            knownPeople: [],
            recognizedPeopleCount: 0,
            transcriptURL: tempDirectory.appendingPathComponent("precommit.md"),
            transcriptId: taskId,
            systemAudioURL: copiedImportURL,
            micAudioURL: nil,
            shouldRemoveTemporaryAudioOnCleanup: true,
            sourceFailedTranscriptionId: nil,
            importedRecoverySession: recoverySession,
            onComplete: { _ in }
        )

        XCTAssertEqual(
            manager.preserveActiveTranscriptionsForShutdown(errorMessage: "test shutdown ordering"),
            1
        )
        manager.cleanupPendingNaming()

        let failed = try XCTUnwrap(manager.failedTranscriptionManager.failedTranscriptions.first)
        XCTAssertTrue(FileManager.default.fileExists(atPath: failed.micAudioURL.path))
        XCTAssertNotNil(failed.systemAudioURL)
        XCTAssertFalse(failed.splitLocalSpeakers)
        XCTAssertEqual(recoverySession.failedQueueHandoffCount, 1)
        XCTAssertEqual(recoverySession.scratchCleanupPreparationCount, 0)
        XCTAssertEqual(recoverySession.scratchCleanupCount, 0)
        XCTAssertNil(manager.speakerNamingRequest)

        speech.release()
    }

    func testImportedRecoverySessionUsesStableIdentityAndWaitsForScratchCleanup() async throws {
        let speech = BlockingMetadataStubSpeechToTextEngine(transcript: "Imported terminal handoff.")
        let manager = makeManager(
            speechToText: speech,
            diarization: MetadataStubDiarizationEngine(segments: singleSpeakerSegments())
        )
        let copiedImportURL = tempDirectory
            .appendingPathComponent("audio", isDirectory: true)
            .appendingPathComponent("imported-terminal-handoff.wav")
        try writeMonoWAV(to: copiedImportURL, duration: 2.5)

        let taskId = UUID()
        let recoverySession = ImportedRecoverySessionSpy(jobID: taskId)
        manager.startImportedTranscription(
            taskId: taskId,
            audioURL: copiedImportURL,
            outputFolder: tempDirectory.appendingPathComponent("transcripts"),
            recoverySession: recoverySession
        )

        try await waitUntil { speech.didStart }
        XCTAssertEqual(recoverySession.transcriptCommitCount, 0)
        XCTAssertEqual(recoverySession.scratchCleanupPreparationCount, 0)
        XCTAssertEqual(recoverySession.scratchCleanupCount, 0)
        XCTAssertTrue(FileManager.default.fileExists(atPath: copiedImportURL.path))

        speech.release()
        try await waitUntil {
            recoverySession.transcriptCommitCount == 1
                && manager.lastSavedTranscriptURL != nil
                && manager.activeTasks.isEmpty
        }

        let transcriptURL = try XCTUnwrap(manager.lastSavedTranscriptURL)
        let frontmatter = try XCTUnwrap(try TranscriptFrontmatter.readValues(from: transcriptURL))
        XCTAssertEqual(TranscriptFrontmatter.captureID(in: frontmatter), taskId)
        XCTAssertEqual(recoverySession.scratchCleanupPreparationCount, 0)
        XCTAssertEqual(recoverySession.scratchCleanupCount, 0, "speaker review still owns scratch audio")

        XCTAssertTrue(manager.deferPendingSpeakerNamingReview(reason: "test cleanup"))
        try await waitUntil {
            recoverySession.scratchCleanupCount == 1
        }
        XCTAssertEqual(recoverySession.scratchCleanupPreparationCount, 1)
        XCTAssertFalse(FileManager.default.fileExists(atPath: copiedImportURL.path))
    }

    func testImportedArchiveFailureDoesNotAuthorizeRecoveryCleanup() async throws {
        let blockedArchiveParent = tempDirectory.appendingPathComponent("blocked-retained-audio")
        try Data([0]).write(to: blockedArchiveParent)
        let manager = makeManager(
            speechToText: MetadataStubSpeechToTextEngine(transcript: "Synthetic imported archive failure."),
            diarization: MetadataStubDiarizationEngine(segments: singleSpeakerSegments()),
            retainedAudioDirectory: blockedArchiveParent.appendingPathComponent("audio")
        )
        let copiedImportURL = tempDirectory
            .appendingPathComponent("audio", isDirectory: true)
            .appendingPathComponent("archive-failure.wav")
        try writeMonoWAV(to: copiedImportURL, duration: 2.5)
        let taskId = UUID()
        let recoverySession = ImportedRecoverySessionSpy(jobID: taskId)

        manager.startImportedTranscription(
            taskId: taskId,
            audioURL: copiedImportURL,
            outputFolder: tempDirectory.appendingPathComponent("transcripts"),
            recoverySession: recoverySession
        )

        try await waitUntil {
            recoverySession.transcriptCommitCount == 1 && manager.activeTasks.isEmpty
        }

        XCTAssertEqual(recoverySession.scratchCleanupPreparationCount, 0)
        XCTAssertEqual(recoverySession.scratchCleanupCount, 0)
        XCTAssertTrue(
            FileManager.default.fileExists(atPath: copiedImportURL.path),
            "archive failure must retain the only audio copy"
        )
    }

    func testFailedShutdownHandoffKeepsImportedRecoverySession() async throws {
        let speech = BlockingMetadataStubSpeechToTextEngine(transcript: "Imported failed handoff.")
        let blockedParent = tempDirectory.appendingPathComponent("blocked-failed-queue")
        try Data([0]).write(to: blockedParent)
        let manager = makeManager(
            speechToText: speech,
            diarization: MetadataStubDiarizationEngine(segments: singleSpeakerSegments()),
            failedQueueURL: blockedParent.appendingPathComponent("failed.json")
        )
        let copiedImportURL = tempDirectory
            .appendingPathComponent("audio", isDirectory: true)
            .appendingPathComponent("failed-handoff.wav")
        try writeMonoWAV(to: copiedImportURL, duration: 2.5)
        let taskId = UUID()
        let recoverySession = ImportedRecoverySessionSpy(jobID: taskId)

        manager.startImportedTranscription(
            taskId: taskId,
            audioURL: copiedImportURL,
            outputFolder: tempDirectory.appendingPathComponent("transcripts"),
            recoverySession: recoverySession
        )
        try await waitUntil { speech.didStart }

        XCTAssertEqual(
            manager.preserveActiveTranscriptionsForShutdown(errorMessage: "test failed handoff"),
            0
        )
        XCTAssertEqual(recoverySession.failedQueueHandoffCount, 0)
        XCTAssertEqual(recoverySession.scratchCleanupPreparationCount, 0)
        XCTAssertEqual(recoverySession.scratchCleanupCount, 0)
        XCTAssertTrue(FileManager.default.fileExists(atPath: copiedImportURL.path))
        speech.release()
    }

    func testStartSavedAudioRetranscriptionDoesNotDeleteSourceWhenRejectedForActiveTask() throws {
        let manager = makeManager()
        let savedAudioDirectory = tempDirectory.appendingPathComponent("saved-meeting-audio", isDirectory: true)
        try FileManager.default.createDirectory(at: savedAudioDirectory, withIntermediateDirectories: true)
        let systemURL = savedAudioDirectory.appendingPathComponent("system_audio.wav")
        try writeMonoWAV(to: systemURL, duration: 2.5)
        let activeTaskId = UUID()
        manager.activeTasks[activeTaskId] = Task {}
        defer {
            manager.activeTasks[activeTaskId]?.cancel()
            manager.activeTasks.removeValue(forKey: activeTaskId)
        }

        manager.startSavedAudioRetranscription(
            micURL: nil,
            systemURL: systemURL,
            outputFolder: tempDirectory.appendingPathComponent("transcripts"),
            meetingTitle: "Saved customer call"
        )

        XCTAssertTrue(FileManager.default.fileExists(atPath: systemURL.path))
        XCTAssertEqual(manager.lastFailureDiagnosticMessage, "Transcription already in progress")
        guard case .failed(let message) = manager.displayStatus else {
            return XCTFail("Expected saved-audio retranscription rejection to publish a failed status")
        }
        XCTAssertEqual(message, "Another transcript is already running. Wait for it to finish, then try again.")
    }

    func testSavedAudioRetranscriptionRequiresQuitConfirmationWithoutClaimingScratchOwnership() async throws {
        let speech = BlockingMetadataStubSpeechToTextEngine(transcript: "Saved audio retry completed.")
        let manager = makeManager(
            speechToText: speech,
            diarization: MetadataStubDiarizationEngine(segments: singleSpeakerSegments(duration: 2.5))
        )
        let savedAudioDirectory = tempDirectory.appendingPathComponent("saved-meeting-audio", isDirectory: true)
        try FileManager.default.createDirectory(at: savedAudioDirectory, withIntermediateDirectories: true)
        let systemURL = savedAudioDirectory.appendingPathComponent("system_audio.wav")
        try writeMonoWAV(to: systemURL, duration: 2.5)

        manager.startSavedAudioRetranscription(
            micURL: nil,
            systemURL: systemURL,
            outputFolder: tempDirectory.appendingPathComponent("transcripts"),
            meetingTitle: "Saved customer call"
        )

        try await waitUntil {
            speech.didStart
        }

        XCTAssertTrue(
            manager.hasActiveTranscriptionWorkRequiringQuitConfirmation,
            "retained-audio retranscription should keep the background-work quit warning enabled"
        )
        XCTAssertFalse(
            manager.hasPreservableActiveTranscriptionAudio,
            "retained source audio must not be misclassified as app-owned scratch audio"
        )

        manager.cancelAll()
        try await waitUntil {
            manager.activeTasks.isEmpty
        }

        XCTAssertFalse(manager.hasActiveTranscriptionWorkRequiringQuitConfirmation)
        XCTAssertTrue(FileManager.default.fileExists(atPath: systemURL.path), "cancellation must keep retained source audio")
    }

    func testSavedAudioReplacementReservesTranscriptUntilCancellationFinishes() async throws {
        let speech = BlockingMetadataStubSpeechToTextEngine(transcript: "Replacement transcript.")
        let manager = makeManager(
            speechToText: speech,
            diarization: MetadataStubDiarizationEngine(segments: singleSpeakerSegments(duration: 2.5))
        )
        let transcriptsDirectory = tempDirectory.appendingPathComponent("transcripts", isDirectory: true)
        try FileManager.default.createDirectory(at: transcriptsDirectory, withIntermediateDirectories: true)
        let originalTranscriptURL = transcriptsDirectory.appendingPathComponent("Saved_Meeting.md")
        try "old transcript".write(to: originalTranscriptURL, atomically: true, encoding: .utf8)
        let savedAudioDirectory = tempDirectory.appendingPathComponent("saved-meeting-audio", isDirectory: true)
        try FileManager.default.createDirectory(at: savedAudioDirectory, withIntermediateDirectories: true)
        let systemURL = savedAudioDirectory.appendingPathComponent("system_audio.wav")
        try writeMonoWAV(to: systemURL, duration: 2.5)

        manager.startSavedAudioRetranscription(
            micURL: nil,
            systemURL: systemURL,
            outputFolder: transcriptsDirectory,
            meetingTitle: "Saved Meeting",
            replacementTranscriptURL: originalTranscriptURL
        )

        try await waitUntil { speech.didStart }
        XCTAssertTrue(TranscriptSaver.isReplacingTranscript(at: originalTranscriptURL))

        manager.cancelAll()
        try await waitUntil {
            !TranscriptSaver.isReplacingTranscript(at: originalTranscriptURL)
        }

        XCTAssertTrue(manager.activeTasks.isEmpty)
        XCTAssertTrue(FileManager.default.fileExists(atPath: systemURL.path))
    }

    /// The replacement reservation is taken inside the task (off the MainActor, so a
    /// long-running speaker rename holding the shared transcript-file serializer cannot
    /// freeze the UI). This covers the resulting failure branch: the reservation is
    /// attempted after the task is already registered, so it has to unwind that
    /// registration itself rather than returning before any bookkeeping happened.
    func testSavedAudioRetranscriptionUnwindsCleanlyWhenReplacementTargetIsMissing() async throws {
        let manager = makeManager(
            speechToText: MetadataStubSpeechToTextEngine(transcript: "Should never run."),
            diarization: MetadataStubDiarizationEngine(segments: singleSpeakerSegments(duration: 2.5))
        )
        let transcriptsDirectory = tempDirectory.appendingPathComponent("transcripts", isDirectory: true)
        try FileManager.default.createDirectory(at: transcriptsDirectory, withIntermediateDirectories: true)
        let savedAudioDirectory = tempDirectory.appendingPathComponent("saved-meeting-audio", isDirectory: true)
        try FileManager.default.createDirectory(at: savedAudioDirectory, withIntermediateDirectories: true)
        let systemURL = savedAudioDirectory.appendingPathComponent("system_audio.wav")
        try writeMonoWAV(to: systemURL, duration: 2.5)

        // Never created: beginReplacingTranscript refuses to reserve a file that is not
        // there, which is the "that meeting moved" case the user-facing copy describes.
        let missingTranscriptURL = transcriptsDirectory.appendingPathComponent("Moved_Meeting.md")
        let pendingReview = SpeakerNamingRequest(
            speakers: [],
            transcriptURL: missingTranscriptURL,
            transcriptId: UUID(),
            systemAudioURL: systemURL,
            micAudioURL: nil,
            shouldRemoveTemporaryAudioOnCleanup: false,
            onComplete: { _ in }
        )
        manager.enqueueSpeakerNamingRequest(pendingReview)

        manager.startSavedAudioRetranscription(
            micURL: nil,
            systemURL: systemURL,
            outputFolder: transcriptsDirectory,
            meetingTitle: "Moved Meeting",
            replacementTranscriptURL: missingTranscriptURL
        )

        try await waitUntil {
            manager.lastFailureDiagnosticMessage == "Replacement transcript unavailable"
        }

        // The task registered before the reservation was attempted, so all three counters
        // have to come back down or the app keeps thinking work is in flight (which also
        // blocks quit and rejects the user's next retranscription as "already running").
        try await waitUntil {
            manager.activeTasks.isEmpty && manager.activeCount == 0 && manager.backgroundTaskCount == 0
        }
        XCTAssertTrue(manager.activeTasks.isEmpty)
        XCTAssertEqual(manager.activeCount, 0)
        XCTAssertEqual(manager.backgroundTaskCount, 0)

        // A failed reservation must not leave the target reserved, or every later speaker
        // rename touching that transcript would fail closed forever.
        XCTAssertFalse(TranscriptSaver.isReplacingTranscript(at: missingTranscriptURL))

        // Retained user audio is never scratch — it survives the rejection untouched.
        XCTAssertTrue(FileManager.default.fileExists(atPath: systemURL.path))
        XCTAssertEqual(
            manager.speakerNamingRequest?.id,
            pendingReview.id,
            "failed replacement setup must leave the original review recoverable"
        )

        guard case .failed(let message) = manager.displayStatus else {
            return XCTFail("Expected a missing replacement target to publish a failed status")
        }
        XCTAssertEqual(message, "That meeting moved or is already being re-transcribed. Refresh and try again.")
    }

    func testStartImportedTranscriptionDoesNotDeleteOutOfSandboxFileAfterSuccess() async throws {
        let manager = makeManager(
            speechToText: MetadataStubSpeechToTextEngine(transcript: "Imported meeting artifact."),
            diarization: MetadataStubDiarizationEngine(segments: [
                SpeakerSegment(
                    speakerId: 1,
                    startTime: 0,
                    endTime: 2,
                    embedding: [Float](repeating: 0.42, count: 256),
                    qualityScore: 0.95
                )
            ])
        )
        let externalURL = tempDirectory.appendingPathComponent("outside-success.wav")
        try writeMonoWAV(to: externalURL, duration: 2.5)

        manager.startImportedTranscription(
            audioURL: externalURL,
            outputFolder: tempDirectory.appendingPathComponent("transcripts"),
            meetingTitle: "Imported customer call"
        )

        try await waitUntil {
            manager.lastSavedTranscriptURL != nil && manager.activeTasks.isEmpty
        }

        XCTAssertTrue(FileManager.default.fileExists(atPath: externalURL.path))
    }

    func testStartImportedTranscriptionUsesSourceRecordingDateForSavedMetadata() async throws {
        let sourceRecordingDate = localDate(
            year: 2025,
            month: 2,
            day: 3,
            hour: 4,
            minute: 5,
            second: 6
        )
        let statsStore = MetadataCapturingStatsStore()
        let manager = makeManager(
            speechToText: MetadataStubSpeechToTextEngine(transcript: "Imported meeting artifact."),
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
        let externalURL = tempDirectory.appendingPathComponent("source-recorded-date.wav")
        try writeMonoWAV(to: externalURL, duration: 2.5)

        manager.startImportedTranscription(
            audioURL: externalURL,
            outputFolder: tempDirectory.appendingPathComponent("transcripts"),
            meetingTitle: "Imported customer call",
            recordingDate: sourceRecordingDate
        )

        try await waitUntil {
            manager.lastSavedTranscriptURL != nil && manager.activeTasks.isEmpty
        }

        let transcriptURL = try XCTUnwrap(manager.lastSavedTranscriptURL)
        let markdown = try String(contentsOf: transcriptURL, encoding: .utf8)
        XCTAssertTrue(
            transcriptURL.lastPathComponent.hasPrefix("Call_\(DateFormattingHelper.formatFilename(sourceRecordingDate))"),
            "imported-audio filenames should use the source recording date"
        )
        XCTAssertTrue(
            markdown.contains("\ndate: \(frontmatterDateString(sourceRecordingDate))\n"),
            "frontmatter date should use the source recording date"
        )
        XCTAssertTrue(
            markdown.contains("\ntime: \(frontmatterTimeString(sourceRecordingDate))\n"),
            "frontmatter time should use the source recording time"
        )
        XCTAssertEqual(statsStore.recordedSessions.count, 1, "successful imports should record stats exactly once")
        let metadata = try XCTUnwrap(statsStore.recordedSessions.first)
        XCTAssertLessThan(
            abs(metadata.date.timeIntervalSince(sourceRecordingDate)),
            0.001,
            "recording metadata should use the source recording date"
        )
    }

    func testStartTranscriptionUsesRecordingDateForSavedMetadata() async throws {
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
            speechToText: MetadataStubSpeechToTextEngine(transcript: "Live meeting artifact."),
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
        let micURL = scratchDirectory.appendingPathComponent("live-recording-date-mic.wav")
        let systemURL = scratchDirectory.appendingPathComponent("live-recording-date-system.wav")
        try writeMonoWAV(to: micURL, duration: 2.5)
        try writeMonoWAV(to: systemURL, duration: 2.5)

        manager.startTranscription(
            micURL: micURL,
            systemURL: systemURL,
            outputFolder: tempDirectory.appendingPathComponent("transcripts"),
            meetingTitle: "Live customer call",
            recordingDate: recordingDate
        )

        try await waitUntil {
            manager.lastSavedTranscriptURL != nil && manager.activeTasks.isEmpty
        }

        let transcriptURL = try XCTUnwrap(manager.lastSavedTranscriptURL)
        let markdown = try String(contentsOf: transcriptURL, encoding: .utf8)
        XCTAssertTrue(
            transcriptURL.lastPathComponent.hasPrefix("Call_\(DateFormattingHelper.formatFilename(recordingDate))"),
            "live recording filenames should use the recording start date"
        )
        XCTAssertTrue(
            markdown.contains("\ndate: \(frontmatterDateString(recordingDate))\n"),
            "frontmatter date should use the live recording start date"
        )
        XCTAssertTrue(
            markdown.contains("\ntime: \(frontmatterTimeString(recordingDate))\n"),
            "frontmatter time should use the live recording start time"
        )
        XCTAssertEqual(statsStore.recordedSessions.count, 1)
        let metadata = try XCTUnwrap(statsStore.recordedSessions.first)
        XCTAssertLessThan(
            abs(metadata.date.timeIntervalSince(recordingDate)),
            0.001,
            "stats metadata should use the live recording start date"
        )
    }

    func testStartImportedTranscriptionSurfacesNoSpeechWhenNoUtterances() async throws {
        let manager = makeManager(
            speechToText: MetadataStubSpeechToTextEngine(transcript: "ignored")
        )
        let externalURL = tempDirectory.appendingPathComponent("outside-no-speech.wav")
        try writeMonoWAV(to: externalURL, duration: 2.5)

        manager.startImportedTranscription(
            audioURL: externalURL,
            outputFolder: tempDirectory.appendingPathComponent("transcripts"),
            meetingTitle: "Quiet recording"
        )

        try await waitUntil {
            if case .failed(let message) = manager.displayStatus,
               manager.activeTasks.isEmpty {
                return message == "No speech was found in that audio file. Choose a file with clear spoken audio and try again."
            }
            return false
        }

        XCTAssertEqual(manager.lastFailureDiagnosticMessage, "No speech detected")
        XCTAssertTrue(FileManager.default.fileExists(atPath: externalURL.path))
        XCTAssertNil(manager.lastSavedTranscriptURL)
    }

    func testImportedMidPipelineFailureArchivesToFailedQueueBeforeDeletingScratch() async throws {
        let retainedAudioDirectory = tempDirectory
            .appendingPathComponent("transcripts", isDirectory: true)
            .appendingPathComponent("audio", isDirectory: true)
        let manager = makeManager(
            speechToText: MetadataStubSpeechToTextEngine(transcript: "ignored"),
            retainedAudioDirectory: retainedAudioDirectory
        )
        let scratchDirectory = tempDirectory.appendingPathComponent("audio")
        try FileManager.default.createDirectory(at: scratchDirectory, withIntermediateDirectories: true)
        let scratchURL = scratchDirectory.appendingPathComponent("imported-mid-pipeline.wav")
        try writeMonoWAV(to: scratchURL, duration: 2.5)
        let taskId = UUID()
        let recoverySession = ImportedRecoverySessionSpy(jobID: taskId)

        manager.startImportedTranscription(
            taskId: taskId,
            audioURL: scratchURL,
            outputFolder: tempDirectory.appendingPathComponent("transcripts"),
            meetingTitle: "Imported mid-pipeline failure",
            recoverySession: recoverySession
        )

        try await waitUntil {
            manager.activeTasks.isEmpty
                && manager.failedTranscriptionManager.failedTranscriptions.count == 1
        }

        let failed = try XCTUnwrap(manager.failedTranscriptionManager.failedTranscriptions.first)
        XCTAssertEqual(failed.id, taskId)
        XCTAssertEqual(failed.meetingTitle, "Imported mid-pipeline failure")
        XCTAssertFalse(failed.splitLocalSpeakers, "imports are system-channel and must not persist local-mic split")
        XCTAssertTrue(failed.micAudioURL.lastPathComponent.hasPrefix("microphone_placeholder"))
        XCTAssertTrue(failed.micAudioURL.path.hasPrefix(retainedAudioDirectory.path + "/"))
        XCTAssertTrue(failed.systemAudioURL?.path.hasPrefix(retainedAudioDirectory.path + "/") ?? false)
        XCTAssertTrue(failed.audioFilesExist())
        XCTAssertTrue(FileManager.default.fileExists(atPath: failed.micAudioURL.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: failed.systemAudioURL?.path ?? ""))
        XCTAssertFalse(
            FileManager.default.fileExists(atPath: scratchURL.path),
            "imported scratch must be deleted only after the failed-queue archive is durable"
        )
        XCTAssertEqual(recoverySession.failedQueueHandoffCount, 1)
        XCTAssertEqual(recoverySession.scratchCleanupCount, 0, "failed-queue handoff owns the journal, not scratch cleanup")
        XCTAssertNil(manager.lastSavedTranscriptURL)
    }

    func testStartImportedTranscriptionRejectsTooShortAudioWithClearCopy() throws {
        let manager = makeManager()
        let scratchDirectory = tempDirectory.appendingPathComponent("audio")
        try FileManager.default.createDirectory(at: scratchDirectory, withIntermediateDirectories: true)
        let scratchURL = scratchDirectory.appendingPathComponent("imported-too-short.wav")
        try writeMonoWAV(to: scratchURL, duration: 1.0)

        manager.startImportedTranscription(
            audioURL: scratchURL,
            outputFolder: tempDirectory.appendingPathComponent("transcripts"),
            meetingTitle: "Short import"
        )

        XCTAssertFalse(FileManager.default.fileExists(atPath: scratchURL.path), "app-managed short import scratch audio should be removed after rejection")
        XCTAssertEqual(manager.activeCount, 0)
        XCTAssertEqual(manager.backgroundTaskCount, 0)
        XCTAssertTrue(manager.activeTasks.isEmpty)
        XCTAssertTrue(
            manager.failedTranscriptionManager.failedTranscriptions.isEmpty,
            "too-short imported audio is an early reject and must not enter the failed queue"
        )
        XCTAssertEqual(manager.lastFailureDiagnosticMessage, "Recording too short")
        guard case .failed(let message) = manager.displayStatus else {
            return XCTFail("Expected too-short imported audio to publish a failed status")
        }
        XCTAssertEqual(
            message,
            "That audio file is too short to transcribe. Choose audio that is at least two seconds long."
        )
    }

    func testSavedAudioRetranscriptionRunsSpeakerIdentificationAndKeepsSourceAudio() async throws {
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
        let savedAudioDirectory = tempDirectory.appendingPathComponent("saved-meeting-audio", isDirectory: true)
        try FileManager.default.createDirectory(at: savedAudioDirectory, withIntermediateDirectories: true)
        let micURL = savedAudioDirectory.appendingPathComponent("microphone.wav")
        let systemURL = savedAudioDirectory.appendingPathComponent("system_audio.wav")
        try writeMonoWAV(to: micURL, duration: 2.5)
        try writeMonoWAV(to: systemURL, duration: 2.5)

        manager.startSavedAudioRetranscription(
            micURL: micURL,
            systemURL: systemURL,
            outputFolder: tempDirectory.appendingPathComponent("transcripts", isDirectory: true),
            meetingTitle: "Saved customer call",
            splitLocalSpeakers: true
        )

        try await waitUntil {
            manager.speakerNamingRequest != nil && manager.activeTasks.isEmpty
        }

        let request = try XCTUnwrap(manager.speakerNamingRequest)
        XCTAssertTrue(
            request.speakers.contains { $0.channel == .mic },
            "saved meeting re-transcription should run local-speaker identification on retained mic audio"
        )
        XCTAssertFalse(
            request.shouldRemoveTemporaryAudioOnCleanup,
            "saved meeting re-transcription must not clean up retained source audio"
        )
        XCTAssertNil(request.sourceFailedTranscriptionId)
        XCTAssertEqual(request.micAudioURL, micURL)
        XCTAssertEqual(request.systemAudioURL, systemURL)
        XCTAssertTrue(FileManager.default.fileExists(atPath: micURL.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: systemURL.path))

        let transcriptURL = try XCTUnwrap(manager.lastSavedTranscriptURL)
        XCTAssertTrue(FileManager.default.fileExists(atPath: transcriptURL.path))
        XCTAssertTrue(
            FileManager.default.fileExists(atPath: retainedAudioDirectory.path),
            "new transcript should still get its own retained-audio archive"
        )
    }

    func testSavedAudioRetranscriptionDefaultsToSingleLocalMicSpeaker() async throws {
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
        let manager = makeManager(
            speechToText: speech,
            diarization: diarization,
            retainedAudioDirectory: tempDirectory
                .appendingPathComponent("transcripts", isDirectory: true)
                .appendingPathComponent("audio", isDirectory: true)
        )
        let savedAudioDirectory = tempDirectory.appendingPathComponent("saved-meeting-audio", isDirectory: true)
        try FileManager.default.createDirectory(at: savedAudioDirectory, withIntermediateDirectories: true)
        let micURL = savedAudioDirectory.appendingPathComponent("microphone.wav")
        let systemURL = savedAudioDirectory.appendingPathComponent("system_audio.wav")
        try writeMonoWAV(to: micURL, duration: 2.5)
        try writeMonoWAV(to: systemURL, duration: 2.5)

        manager.startSavedAudioRetranscription(
            micURL: micURL,
            systemURL: systemURL,
            outputFolder: tempDirectory.appendingPathComponent("transcripts", isDirectory: true),
            meetingTitle: "Saved customer call"
        )

        try await waitUntil {
            manager.speakerNamingRequest != nil && manager.activeTasks.isEmpty
        }

        let request = try XCTUnwrap(manager.speakerNamingRequest)
        XCTAssertTrue(
            request.speakers.contains { $0.channel == .system },
            "saved meeting re-transcription should still identify system-audio speakers"
        )
        XCTAssertFalse(
            request.speakers.contains { $0.channel == .mic },
            "saved meeting re-transcription should not split local mic speakers unless the app opts in"
        )
        XCTAssertTrue(FileManager.default.fileExists(atPath: micURL.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: systemURL.path))
    }

    func testSavedAudioRetranscriptionCanReplaceOriginalTranscriptWithoutDuplicateRow() async throws {
        let originalRecordingDate = localDate(
            year: 2026,
            month: 6,
            day: 5,
            hour: 18,
            minute: 39,
            second: 20
        )
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
        let originalTranscriptId = UUID()
        let statsStore = MetadataCapturingStatsStore()
        let transcriptsDirectory = tempDirectory.appendingPathComponent("transcripts", isDirectory: true)
        let retainedAudioDirectory = transcriptsDirectory.appendingPathComponent("audio", isDirectory: true)
        let manager = makeManager(
            speechToText: speech,
            diarization: diarization,
            retainedAudioDirectory: retainedAudioDirectory,
            statsStore: statsStore
        )
        try FileManager.default.createDirectory(at: transcriptsDirectory, withIntermediateDirectories: true)

        let originalTranscriptURL = transcriptsDirectory.appendingPathComponent("Reviewed_Call.md")
        try """
        ---
        capture_id: "\(originalTranscriptId.uuidString)"
        transcript_id: "\(originalTranscriptId.uuidString)"
        capture_type: meeting
        title: "Reviewed Call"
        date: 2026-06-05
        time: 18:39:20
        duration: "00:02"
        total_word_count: 1
        mic_utterances: 1
        system_utterances: 1
        ---

        # Reviewed Call

        ## Transcript

        **00:01** [System/Speaker 1]
        Old synthetic line.
        """.write(to: originalTranscriptURL, atomically: true, encoding: .utf8)

        let savedAudioDirectory = retainedAudioDirectory
            .appendingPathComponent("Reviewed_Call_audio", isDirectory: true)
        try FileManager.default.createDirectory(at: savedAudioDirectory, withIntermediateDirectories: true)
        let micURL = savedAudioDirectory.appendingPathComponent("microphone.wav")
        let systemURL = savedAudioDirectory.appendingPathComponent("system_audio.wav")
        try writeMonoWAV(to: micURL, duration: 2.5)
        try writeMonoWAV(to: systemURL, duration: 2.5)
        var committedReplacementURLs: [URL] = []

        manager.startSavedAudioRetranscription(
            micURL: micURL,
            systemURL: systemURL,
            outputFolder: transcriptsDirectory,
            meetingTitle: "Reviewed Call",
            splitLocalSpeakers: true,
            replacementTranscriptURL: originalTranscriptURL,
            recordingDate: originalRecordingDate,
            onReplacementTranscriptCommitted: { url in
                committedReplacementURLs.append(url)
            }
        )

        try await waitUntil {
            manager.speakerNamingRequest != nil && manager.activeTasks.isEmpty
        }

        let request = try XCTUnwrap(manager.speakerNamingRequest)
        let transcriptURL = try XCTUnwrap(manager.lastSavedTranscriptURL)
        let markdown = try String(contentsOf: originalTranscriptURL, encoding: .utf8)
        let markdownFiles = try FileManager.default.contentsOfDirectory(
            at: transcriptsDirectory,
            includingPropertiesForKeys: nil
        ).filter { $0.pathExtension == "md" }
        let retainedAudioFiles = try FileManager.default.contentsOfDirectory(
            at: savedAudioDirectory,
            includingPropertiesForKeys: nil
        ).map(\.lastPathComponent).sorted()

        XCTAssertEqual(transcriptURL, originalTranscriptURL, "replacement retranscription should publish the original row URL")
        XCTAssertEqual(request.transcriptURL, originalTranscriptURL, "speaker review should continue against the original transcript")
        XCTAssertEqual(markdownFiles.count, 1, "replacement retranscription should not create a duplicate meeting Markdown row")
        XCTAssertEqual(
            markdownFiles.first?.standardizedFileURL.path,
            originalTranscriptURL.standardizedFileURL.path,
            "the remaining meeting Markdown row should still be the original transcript"
        )
        XCTAssertTrue(
            markdown.contains("\ndate: \(frontmatterDateString(originalRecordingDate))\n"),
            "replacement transcript should keep the original meeting date in frontmatter"
        )
        XCTAssertTrue(
            markdown.contains("\ntime: \(frontmatterTimeString(originalRecordingDate))\n"),
            "replacement transcript should keep the original meeting time in frontmatter"
        )
        XCTAssertEqual(
            retainedAudioFiles,
            ["microphone.wav", "system_audio.wav"],
            "replacement retranscription should reuse retained audio instead of copying duplicate files into the same archive"
        )
        XCTAssertEqual(
            statsStore.recordedSessions.map(\.id),
            [originalTranscriptId.uuidString],
            "replacement retranscription should update stats for the existing transcript ID instead of creating a second history row"
        )
        XCTAssertEqual(
            committedReplacementURLs,
            [originalTranscriptURL],
            "replacement retranscription should notify the app only after the selected transcript is committed"
        )
        XCTAssertTrue(FileManager.default.fileExists(atPath: micURL.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: systemURL.path))
    }

    func testSavedAudioRetranscriptionRejectsTooShortAudioWithoutDeletingSource() throws {
        let manager = makeManager()
        let savedAudioDirectory = tempDirectory.appendingPathComponent("saved-meeting-audio", isDirectory: true)
        try FileManager.default.createDirectory(at: savedAudioDirectory, withIntermediateDirectories: true)
        let systemURL = savedAudioDirectory.appendingPathComponent("system_audio.wav")
        try writeMonoWAV(to: systemURL, duration: 1.0)

        manager.startSavedAudioRetranscription(
            micURL: nil,
            systemURL: systemURL,
            outputFolder: tempDirectory.appendingPathComponent("transcripts"),
            meetingTitle: "Short saved call"
        )

        XCTAssertTrue(FileManager.default.fileExists(atPath: systemURL.path))
        XCTAssertEqual(manager.activeCount, 0)
        XCTAssertEqual(manager.backgroundTaskCount, 0)
        XCTAssertTrue(manager.activeTasks.isEmpty)
        XCTAssertTrue(manager.failedTranscriptionManager.failedTranscriptions.isEmpty)
        XCTAssertEqual(manager.lastFailureDiagnosticMessage, "Recording too short")
        guard case .failed(let message) = manager.displayStatus else {
            return XCTFail("Expected too-short saved audio to publish a failed status")
        }
        XCTAssertEqual(message, "That saved audio is too short to transcribe again.")
    }

    func testSavedAudioRetranscriptionUsesSavedAudioFailureCopyAfterPipelineFailure() async throws {
        let manager = makeManager(
            speechToText: MetadataStubSpeechToTextEngine(transcript: "ignored")
        )
        let savedAudioDirectory = tempDirectory.appendingPathComponent("saved-meeting-audio", isDirectory: true)
        try FileManager.default.createDirectory(at: savedAudioDirectory, withIntermediateDirectories: true)
        let systemURL = savedAudioDirectory.appendingPathComponent("system_audio.wav")
        try writeMonoWAV(to: systemURL, duration: 2.5)

        manager.startSavedAudioRetranscription(
            micURL: nil,
            systemURL: systemURL,
            outputFolder: tempDirectory.appendingPathComponent("transcripts"),
            meetingTitle: "Quiet saved call"
        )

        try await waitUntil {
            if case .failed(let message) = manager.displayStatus,
               manager.activeTasks.isEmpty {
                return message == "No speech was found in that saved audio. Try a recording with clearer spoken audio."
            }
            return false
        }

        XCTAssertEqual(manager.lastFailureDiagnosticMessage, "No speech detected")
        XCTAssertTrue(FileManager.default.fileExists(atPath: systemURL.path))
        XCTAssertNil(manager.lastSavedTranscriptURL)
    }

    func testSavedAudioRetranscriptionUsesSavedAudioFailureCopy() {
        XCTAssertEqual(
            TranscriptionTaskManager.savedAudioRetranscriptionFailureDisplayMessage(
                forDiagnosticMessage: "No speech detected"
            ),
            "No speech was found in that saved audio. Try a recording with clearer spoken audio."
        )
        XCTAssertEqual(
            TranscriptionTaskManager.savedAudioRetranscriptionFailureDisplayMessage(
                forDiagnosticMessage: "Invalid audio format"
            ),
            "Transcripted couldn't read that saved audio. Try another retained recording."
        )
        XCTAssertFalse(
            TranscriptionTaskManager.savedAudioRetranscriptionFailureDisplayMessage(
                forDiagnosticMessage: "Transcription inference failed"
            ).contains("import"),
            "saved-audio failures should not tell the user to import the file again"
        )
    }

}
