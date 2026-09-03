import XCTest
import Combine
import AVFoundation
import FluidAudio
@testable import TranscriptedCore

@available(macOS 14.0, *)
@MainActor
extension TranscriptionTaskManagerMetadataTests {
    func testStartTranscriptionAllowsMicOnlyRecovery() async throws {
        let manager = makeManager(
            speechToText: MetadataStubSpeechToTextEngine(transcript: "Mic only recovery worked.")
        )
        let micScratchDirectory = tempDirectory.appendingPathComponent("audio")
        try FileManager.default.createDirectory(at: micScratchDirectory, withIntermediateDirectories: true)
        let micURL = micScratchDirectory.appendingPathComponent("mic.wav")
        try writeMonoWAV(to: micURL, duration: 2.5)

        manager.startTranscription(
            micURL: micURL,
            systemURL: nil,
            outputFolder: tempDirectory.appendingPathComponent("transcripts")
        )

        try await waitUntil {
            manager.lastSavedTranscriptURL != nil && manager.activeTasks.isEmpty
        }

        XCTAssertEqual(manager.activeCount, 0)
        XCTAssertEqual(manager.backgroundTaskCount, 0)
        XCTAssertEqual(manager.activeTasks.count, 0)
        XCTAssertTrue(manager.failedTranscriptionManager.failedTranscriptions.isEmpty)
        XCTAssertEqual(manager.displayStatus, .transcriptSaved)

        let transcriptURL = try XCTUnwrap(manager.lastSavedTranscriptURL)
        let markdown = try String(contentsOf: transcriptURL, encoding: .utf8)
        XCTAssertTrue(markdown.contains("sources: [mic]"))
        XCTAssertTrue(markdown.contains("system_audio_missing: true"))
        XCTAssertTrue(markdown.contains("Mic only recovery worked."))
    }

    func testStartTranscriptionAllowsSystemOnlyRecovery() async throws {
        let retainedAudioDirectory = tempDirectory
            .appendingPathComponent("transcripts", isDirectory: true)
            .appendingPathComponent("audio", isDirectory: true)
        let manager = makeManager(
            speechToText: MetadataStubSpeechToTextEngine(transcript: "Remote system audio survived."),
            diarization: MetadataStubDiarizationEngine(segments: singleSpeakerSegments(duration: 2.5)),
            retainedAudioDirectory: retainedAudioDirectory
        )
        let scratchDirectory = tempDirectory.appendingPathComponent("audio")
        let systemURL = scratchDirectory.appendingPathComponent("system-only.wav")
        try writeMonoWAV(to: systemURL, duration: 2.5)
        let expectedMicURL = scratchDirectory.appendingPathComponent("system-only-mic.wav")
        let journalURL = scratchDirectory.appendingPathComponent("system-only-mic.recording.json")
        let journal = MeetingRecordingJournalStore(directory: scratchDirectory)
        let journalSession = journal.begin(primaryMicURL: expectedMicURL)
        journal.recordSystemAudio(systemURL, session: journalSession)
        journal.flush()

        manager.startTranscription(
            micURL: nil,
            systemURL: systemURL,
            outputFolder: tempDirectory.appendingPathComponent("transcripts"),
            meetingTitle: "System-only recovery"
        )

        try await waitUntil {
            manager.lastSavedTranscriptURL != nil && manager.activeTasks.isEmpty
        }

        XCTAssertTrue(manager.failedTranscriptionManager.failedTranscriptions.isEmpty)
        let transcriptURL = try XCTUnwrap(manager.lastSavedTranscriptURL)
        let markdown = try String(contentsOf: transcriptURL, encoding: .utf8)
        let values = try XCTUnwrap(try TranscriptFrontmatter.readValues(from: transcriptURL))
        XCTAssertEqual(values["sources"], "[system_audio]")
        XCTAssertEqual(values["capture_quality"], "degraded")
        XCTAssertEqual(values["microphone_audio_unusable"], "true")
        XCTAssertFalse(markdown.contains("### Microphone"))
        XCTAssertTrue(markdown.contains("Remote system audio survived."))
        XCTAssertTrue(markdown.contains("The microphone track was missing or could not be transcribed"))
        let retainedFiles = FileManager.default
            .enumerator(at: retainedAudioDirectory, includingPropertiesForKeys: nil)?
            .compactMap { $0 as? URL } ?? []
        XCTAssertTrue(retainedFiles.contains { $0.lastPathComponent == "recording.wav" })
        XCTAssertFalse(
            FileManager.default.fileExists(atPath: journalURL.path),
            "a saved system-only transcript must retire the recording journal"
        )
    }

    func testPartialSuccessfulArchiveRemovesCopiedSystemScratch() async throws {
        let retainedAudioDirectory = tempDirectory
            .appendingPathComponent("transcripts", isDirectory: true)
            .appendingPathComponent("audio", isDirectory: true)
        let manager = makeManager(
            speechToText: MetadataStubSpeechToTextEngine(transcript: "Remote audio remained useful."),
            diarization: MetadataStubDiarizationEngine(segments: singleSpeakerSegments(duration: 2.5)),
            retainedAudioDirectory: retainedAudioDirectory
        )
        let scratchDirectory = tempDirectory.appendingPathComponent("audio")
        let missingMicURL = scratchDirectory.appendingPathComponent("missing-mic.wav")
        let systemURL = scratchDirectory.appendingPathComponent("partial-system.wav")
        try writeMonoWAV(to: systemURL, duration: 2.5)

        manager.startTranscription(
            micURL: missingMicURL,
            systemURL: systemURL,
            outputFolder: tempDirectory.appendingPathComponent("transcripts"),
            meetingTitle: "Partial archive cleanup"
        )

        try await waitUntil {
            manager.lastSavedTranscriptURL != nil && manager.activeTasks.isEmpty
        }

        if let request = manager.speakerNamingRequest {
            XCTAssertFalse(request.shouldRemoveMicAudioOnCleanup)
            XCTAssertTrue(request.shouldRemoveSystemAudioOnCleanup)
            manager.cancelSpeakerNamingRequest(transcriptId: request.transcriptId)
            try await waitUntil {
                manager.speakerNamingRequest == nil
            }
        }

        try await waitUntil {
            !FileManager.default.fileExists(atPath: systemURL.path)
        }
        XCTAssertFalse(
            FileManager.default.fileExists(atPath: systemURL.path),
            "a source with a durable retained copy must not remain as orphaned scratch audio"
        )
        let retainedFiles = FileManager.default
            .enumerator(at: retainedAudioDirectory, includingPropertiesForKeys: nil)?
            .compactMap { $0 as? URL } ?? []
        XCTAssertTrue(retainedFiles.contains { $0.lastPathComponent == "system_audio.wav" })
    }

    func testStartTranscriptionRejectsTooShortLiveAudioWithoutQueueingRetry() throws {
        let manager = makeManager()
        let scratchDirectory = tempDirectory.appendingPathComponent("audio")
        try FileManager.default.createDirectory(at: scratchDirectory, withIntermediateDirectories: true)
        let micURL = scratchDirectory.appendingPathComponent("mic.wav")
        let systemURL = scratchDirectory.appendingPathComponent("system_audio.wav")
        try writeMonoWAV(to: micURL, duration: 1.0)
        try writeMonoWAV(to: systemURL, duration: 1.0)

        manager.startTranscription(
            micURL: micURL,
            systemURL: systemURL,
            outputFolder: tempDirectory.appendingPathComponent("transcripts")
        )

        XCTAssertFalse(FileManager.default.fileExists(atPath: micURL.path), "too-short live mic scratch audio should be cleaned up")
        XCTAssertFalse(FileManager.default.fileExists(atPath: systemURL.path), "too-short live system scratch audio should be cleaned up")
        XCTAssertEqual(manager.activeCount, 0)
        XCTAssertEqual(manager.backgroundTaskCount, 0)
        XCTAssertTrue(manager.activeTasks.isEmpty)
        XCTAssertTrue(manager.failedTranscriptionManager.failedTranscriptions.isEmpty)
        XCTAssertEqual(manager.lastFailureDiagnosticMessage, "Recording too short")
        guard case .failed(let message) = manager.displayStatus else {
            return XCTFail("Expected too-short live audio to publish a failed status")
        }
        XCTAssertEqual(message, "Recording too short")
    }

    func testMicOnlyTranscriptionRetainsMicAudioAndRemovesScratch() async throws {
        let retainedAudioDirectory = tempDirectory
            .appendingPathComponent("transcripts", isDirectory: true)
            .appendingPathComponent("audio", isDirectory: true)
        let manager = makeManager(
            speechToText: MetadataStubSpeechToTextEngine(transcript: "Recovered from the microphone."),
            retainedAudioDirectory: retainedAudioDirectory
        )
        let micScratchDirectory = tempDirectory.appendingPathComponent("audio")
        try FileManager.default.createDirectory(at: micScratchDirectory, withIntermediateDirectories: true)
        let micURL = micScratchDirectory.appendingPathComponent("mic.wav")
        try writeMonoWAV(to: micURL, duration: 2.5)

        manager.startTranscription(
            micURL: micURL,
            systemURL: nil,
            outputFolder: tempDirectory.appendingPathComponent("transcripts")
        )

        try await waitUntil {
            manager.lastSavedTranscriptURL != nil && manager.activeTasks.isEmpty
        }

        XCTAssertTrue(manager.failedTranscriptionManager.failedTranscriptions.isEmpty)
        XCTAssertFalse(FileManager.default.fileExists(atPath: micURL.path), "scratch mic audio should be removed after archiving")

        let retainedFiles = FileManager.default
            .enumerator(at: retainedAudioDirectory, includingPropertiesForKeys: nil)?
            .compactMap { $0 as? URL } ?? []
        XCTAssertTrue(
            retainedFiles.contains { $0.lastPathComponent == "microphone.wav" },
            "successful mic-only transcription should retain the microphone WAV beside the transcript"
        )
    }

    func testMicOnlyFailedQueueRetainsArchiveAndRemovesScratch() throws {
        let retainedAudioDirectory = tempDirectory
            .appendingPathComponent("transcripts", isDirectory: true)
            .appendingPathComponent("audio", isDirectory: true)
        let manager = makeManager(retainedAudioDirectory: retainedAudioDirectory)
        let micScratchDirectory = tempDirectory.appendingPathComponent("audio")
        try FileManager.default.createDirectory(at: micScratchDirectory, withIntermediateDirectories: true)
        let micURL = micScratchDirectory.appendingPathComponent("mic.wav")
        try writeMonoWAV(to: micURL, duration: 2.5)

        XCTAssertTrue(manager.addFailedTranscriptionRetainingAvailableAudio(
            micAudioURL: micURL,
            systemAudioURL: nil,
            errorMessage: "Meeting saved before quit. Audio is safe; finish the transcript from Home after reopening."
        ))

        let failed = try XCTUnwrap(manager.failedTranscriptionManager.failedTranscriptions.first)
        XCTAssertTrue(
            failed.micAudioURL.path.hasPrefix(retainedAudioDirectory.path + "/"),
            "failed queue should point at retained archive audio, not scratch audio"
        )
        XCTAssertTrue(FileManager.default.fileExists(atPath: failed.micAudioURL.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: micURL.path), "scratch mic audio should be removed after archiving")

        let archivedDirectory = failed.micAudioURL.deletingLastPathComponent()
        manager.failedTranscriptionManager.deleteFailedTranscription(id: failed.id)

        XCTAssertFalse(FileManager.default.fileExists(atPath: failed.micAudioURL.path), "delete should remove archived failed audio")
        XCTAssertFalse(FileManager.default.fileExists(atPath: archivedDirectory.path), "delete should remove the empty failed-audio directory")
    }

    func testManualFailedQueueRetainsAudioBeforeRemovingScratch() throws {
        let retainedAudioDirectory = tempDirectory
            .appendingPathComponent("transcripts", isDirectory: true)
            .appendingPathComponent("audio", isDirectory: true)
        let manager = makeManager(retainedAudioDirectory: retainedAudioDirectory)
        let scratchDirectory = tempDirectory.appendingPathComponent("audio")
        try FileManager.default.createDirectory(at: scratchDirectory, withIntermediateDirectories: true)
        let micURL = scratchDirectory.appendingPathComponent("mic.wav")
        let systemURL = scratchDirectory.appendingPathComponent("system.wav")
        try writeMonoWAV(to: micURL, duration: 2.5)
        try writeMonoWAV(to: systemURL, duration: 2.5)

        manager.addFailedTranscriptionRetainingAvailableAudio(
            micAudioURL: micURL,
            systemAudioURL: systemURL,
            errorMessage: "Recording stop timed out before audio files were finalized."
        )

        let failed = try XCTUnwrap(manager.failedTranscriptionManager.failedTranscriptions.first)
        XCTAssertTrue(failed.micAudioURL.path.hasPrefix(retainedAudioDirectory.path + "/"))
        XCTAssertTrue(failed.systemAudioURL?.path.hasPrefix(retainedAudioDirectory.path + "/") ?? false)
        XCTAssertFalse(FileManager.default.fileExists(atPath: micURL.path), "scratch mic audio should be removed after archive")
        XCTAssertFalse(FileManager.default.fileExists(atPath: systemURL.path), "scratch system audio should be removed after archive")
    }

    func testAsyncFailedQueueArchivesBeforePersistingFailedRow() async throws {
        let retainedAudioDirectory = tempDirectory
            .appendingPathComponent("transcripts", isDirectory: true)
            .appendingPathComponent("audio", isDirectory: true)
        let manager = makeManager(retainedAudioDirectory: retainedAudioDirectory)
        let scratchDirectory = tempDirectory.appendingPathComponent("audio")
        try FileManager.default.createDirectory(at: scratchDirectory, withIntermediateDirectories: true)
        let micURL = scratchDirectory.appendingPathComponent("mic.wav")
        let systemURL = scratchDirectory.appendingPathComponent("system.wav")
        try writeMonoWAV(to: micURL, duration: 2.5)
        try writeMonoWAV(to: systemURL, duration: 2.5)

        let didQueue = await manager.addFailedTranscriptionRetainingAvailableAudioAfterArchive(
            micAudioURL: micURL,
            systemAudioURL: systemURL,
            errorMessage: "Transcription inference failed",
            taskId: UUID(uuidString: "00000000-0000-0000-0000-000000000149")!,
            meetingTitle: "Recovery Check",
            recordingDate: Date(timeIntervalSince1970: 1_797_000_000)
        )

        XCTAssertTrue(didQueue)
        let failed = try XCTUnwrap(manager.failedTranscriptionManager.failedTranscriptions.first)
        XCTAssertEqual(failed.meetingTitle, "Recovery Check")
        XCTAssertTrue(failed.micAudioURL.path.hasPrefix(retainedAudioDirectory.path + "/"))
        XCTAssertTrue(failed.systemAudioURL?.path.hasPrefix(retainedAudioDirectory.path + "/") ?? false)
        XCTAssertTrue(FileManager.default.fileExists(atPath: failed.micAudioURL.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: failed.systemAudioURL?.path ?? ""))
        XCTAssertFalse(FileManager.default.fileExists(atPath: micURL.path), "scratch mic audio should be removed after retained archive is persisted")
        XCTAssertFalse(FileManager.default.fileExists(atPath: systemURL.path), "scratch system audio should be removed after retained archive is persisted")
    }

    func testManualFailedQueueRemovesRetainedAudioWhenQueuePersistenceFails() throws {
        let retainedAudioDirectory = tempDirectory
            .appendingPathComponent("transcripts", isDirectory: true)
            .appendingPathComponent("audio", isDirectory: true)
        let manager = makeManager(retainedAudioDirectory: retainedAudioDirectory)
        let scratchDirectory = tempDirectory.appendingPathComponent("audio")
        try FileManager.default.createDirectory(at: scratchDirectory, withIntermediateDirectories: true)
        let micURL = scratchDirectory.appendingPathComponent("mic.wav")
        let systemURL = scratchDirectory.appendingPathComponent("system.wav")
        try writeMonoWAV(to: micURL, duration: 2.5)
        try writeMonoWAV(to: systemURL, duration: 2.5)
        try FileManager.default.createDirectory(
            at: tempDirectory.appendingPathComponent("failed_transcriptions.json"),
            withIntermediateDirectories: true
        )

        let didQueue = manager.addFailedTranscriptionRetainingAvailableAudio(
            micAudioURL: micURL,
            systemAudioURL: systemURL,
            errorMessage: "Temporary transcription failure"
        )

        XCTAssertFalse(didQueue)
        XCTAssertTrue(manager.failedTranscriptionManager.failedTranscriptions.isEmpty)
        XCTAssertTrue(FileManager.default.fileExists(atPath: micURL.path), "scratch mic audio should stay when queue persistence fails")
        XCTAssertTrue(FileManager.default.fileExists(atPath: systemURL.path), "scratch system audio should stay when queue persistence fails")
        let retainedChildren = (try? FileManager.default.contentsOfDirectory(
            at: retainedAudioDirectory,
            includingPropertiesForKeys: nil
        )) ?? []
        XCTAssertTrue(retainedChildren.isEmpty, "failed queue persistence should not leave orphan retained audio")
    }

    func testSystemOnlyFailedQueueCreatesPlaceholderAndRetainsSystemAudio() throws {
        let retainedAudioDirectory = tempDirectory
            .appendingPathComponent("transcripts", isDirectory: true)
            .appendingPathComponent("audio", isDirectory: true)
        let manager = makeManager(retainedAudioDirectory: retainedAudioDirectory)
        let scratchDirectory = tempDirectory.appendingPathComponent("audio")
        try FileManager.default.createDirectory(at: scratchDirectory, withIntermediateDirectories: true)
        let systemURL = scratchDirectory.appendingPathComponent("system.wav")
        try writeMonoWAV(to: systemURL, duration: 2.5)
        let expectedMicURL = scratchDirectory.appendingPathComponent("system-only-mic.wav")
        let journalURL = scratchDirectory.appendingPathComponent("system-only-mic.recording.json")
        let journal = MeetingRecordingJournalStore(directory: scratchDirectory)
        let journalSession = journal.begin(primaryMicURL: expectedMicURL)
        journal.recordSystemAudio(systemURL, session: journalSession)
        journal.flush()

        let didQueue = manager.addFailedTranscriptionRetainingAvailableAudio(
            micAudioURL: nil,
            systemAudioURL: systemURL,
            errorMessage: "Recording stopped without microphone audio."
        )

        XCTAssertTrue(didQueue)
        let failed = try XCTUnwrap(manager.failedTranscriptionManager.failedTranscriptions.first)
        XCTAssertEqual(failed.micAudioURL.lastPathComponent, "microphone_placeholder.wav")
        XCTAssertTrue(failed.micAudioURL.path.hasPrefix(retainedAudioDirectory.path + "/"))
        XCTAssertTrue(failed.systemAudioURL?.path.hasPrefix(retainedAudioDirectory.path + "/") ?? false)
        XCTAssertTrue(FileManager.default.fileExists(atPath: failed.micAudioURL.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: failed.systemAudioURL?.path ?? ""))
        XCTAssertFalse(FileManager.default.fileExists(atPath: systemURL.path), "scratch system audio should be removed after archive")
        XCTAssertFalse(
            FileManager.default.fileExists(atPath: journalURL.path),
            "a persisted system-only failed row must retire the recording journal"
        )

        let originalPlaceholderURL = failed.micAudioURL
        let originalRetainedSystemURL = try XCTUnwrap(failed.systemAudioURL)
        XCTAssertTrue(manager.promoteFinalizedFailedTranscriptionAudio(
            id: failed.id,
            micAudioURL: scratchDirectory.appendingPathComponent("still-missing-mic.wav"),
            systemAudioURL: originalRetainedSystemURL
        ))
        let promoted = try XCTUnwrap(
            manager.failedTranscriptionManager.failedTranscriptions.first(where: { $0.id == failed.id })
        )
        XCTAssertNotEqual(promoted.micAudioURL, originalPlaceholderURL)
        XCTAssertNotEqual(promoted.systemAudioURL, originalRetainedSystemURL)
        XCTAssertFalse(
            FileManager.default.fileExists(atPath: originalPlaceholderURL.path),
            "re-archiving must remove the superseded retained mic placeholder"
        )
        XCTAssertFalse(
            FileManager.default.fileExists(atPath: originalRetainedSystemURL.path),
            "re-archiving must remove the superseded retained system source"
        )
        XCTAssertTrue(promoted.audioFilesExist())
    }

    func testMissingMicPathUsesPlaceholderAndSystemAudioSurvivesQueueReload() throws {
        let retainedAudioDirectory = tempDirectory
            .appendingPathComponent("transcripts", isDirectory: true)
            .appendingPathComponent("audio", isDirectory: true)
        let failedQueueURL = tempDirectory.appendingPathComponent("failed_transcriptions.json")
        let manager = makeManager(
            retainedAudioDirectory: retainedAudioDirectory,
            failedQueueURL: failedQueueURL
        )
        let scratchDirectory = tempDirectory.appendingPathComponent("audio")
        let missingMicURL = scratchDirectory.appendingPathComponent("never-created-mic.wav")
        let systemURL = scratchDirectory.appendingPathComponent("system.wav")
        try writeMonoWAV(to: systemURL, duration: 2.5)

        XCTAssertTrue(manager.addFailedTranscriptionRetainingAvailableAudio(
            micAudioURL: missingMicURL,
            systemAudioURL: systemURL,
            errorMessage: "System-only recovery fixture"
        ))

        let firstRow = try XCTUnwrap(manager.failedTranscriptionManager.failedTranscriptions.first)
        XCTAssertTrue(firstRow.micAudioURL.lastPathComponent.hasPrefix("microphone_placeholder"))
        XCTAssertTrue(firstRow.audioFilesExist())

        let reloadedManager = makeManager(
            retainedAudioDirectory: retainedAudioDirectory,
            failedQueueURL: failedQueueURL
        )
        let reloadedRow = try XCTUnwrap(reloadedManager.failedTranscriptionManager.failedTranscriptions.first)
        XCTAssertTrue(reloadedRow.micAudioURL.lastPathComponent.hasPrefix("microphone_placeholder"))
        XCTAssertTrue(reloadedRow.audioFilesExist(), "a reload must keep both the placeholder and retained system track retryable")
    }

    func testUnreadableAudioIsPreservedForRetryInsteadOfDeletedAsTooShort() async throws {
        let retainedAudioDirectory = tempDirectory
            .appendingPathComponent("transcripts", isDirectory: true)
            .appendingPathComponent("audio", isDirectory: true)
        let manager = makeManager(retainedAudioDirectory: retainedAudioDirectory)
        let scratchDirectory = tempDirectory.appendingPathComponent("audio")
        let micURL = scratchDirectory.appendingPathComponent("mic.wav")
        let systemURL = scratchDirectory.appendingPathComponent("system.wav")
        try Data("not-a-wav".utf8).write(to: micURL)
        try Data("also-not-a-wav".utf8).write(to: systemURL)

        manager.startTranscription(
            micURL: micURL,
            systemURL: systemURL,
            outputFolder: tempDirectory.appendingPathComponent("transcripts")
        )

        try await waitUntil {
            manager.activeCount == 0 && manager.failedTranscriptionManager.failedTranscriptions.count == 1
        }
        let failed = try XCTUnwrap(manager.failedTranscriptionManager.failedTranscriptions.first)
        XCTAssertNotEqual(failed.errorMessage, "Recording too short")
        XCTAssertTrue(failed.audioFilesExist())
        XCTAssertTrue(failed.micAudioURL.path.hasPrefix(retainedAudioDirectory.path + "/"))
        XCTAssertTrue(failed.systemAudioURL?.path.hasPrefix(retainedAudioDirectory.path + "/") ?? false)
    }

    func testLiveMidPipelineFailurePersistsSplitLocalSpeakers() async throws {
        let retainedAudioDirectory = tempDirectory
            .appendingPathComponent("transcripts", isDirectory: true)
            .appendingPathComponent("audio", isDirectory: true)
        let manager = makeManager(
            speechToText: MetadataStubSpeechToTextEngine(transcript: "ignored"),
            retainedAudioDirectory: retainedAudioDirectory
        )
        let scratchDirectory = tempDirectory.appendingPathComponent("audio")
        let micURL = scratchDirectory.appendingPathComponent("split-mic.wav")
        let systemURL = scratchDirectory.appendingPathComponent("split-system.wav")
        try writeMonoWAV(to: micURL, duration: 2.5)
        try writeMonoWAV(to: systemURL, duration: 2.5)

        manager.startTranscription(
            micURL: micURL,
            systemURL: systemURL,
            outputFolder: tempDirectory.appendingPathComponent("transcripts"),
            splitLocalSpeakers: true
        )

        try await waitUntil {
            manager.activeCount == 0 && manager.failedTranscriptionManager.failedTranscriptions.count == 1
        }
        let failed = try XCTUnwrap(manager.failedTranscriptionManager.failedTranscriptions.first)
        XCTAssertTrue(failed.splitLocalSpeakers, "live recorded jobs must persist the task's split flag")
        XCTAssertTrue(failed.audioFilesExist())
    }

    func testLiveMeetingDurationUsesLongestReadableTrack() async throws {
        let speech = MetadataStubSpeechToTextEngine(transcript: "Thanks for joining.")
        let diarization = MetadataStubDiarizationEngine(segments: [
            SpeakerSegment(
                speakerId: 1,
                startTime: 0,
                endTime: 3.5,
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
        let scratchDirectory = tempDirectory.appendingPathComponent("audio")
        let micURL = scratchDirectory.appendingPathComponent("short-mic.wav")
        let systemURL = scratchDirectory.appendingPathComponent("long-system.wav")
        try writeMonoWAV(to: micURL, duration: 2.5)
        try writeMonoWAV(to: systemURL, duration: 4.0)

        manager.startTranscription(
            micURL: micURL,
            systemURL: systemURL,
            outputFolder: tempDirectory.appendingPathComponent("transcripts"),
            meetingTitle: "Long system call"
        )

        try await waitUntil {
            manager.lastSavedTranscriptURL != nil && manager.activeTasks.isEmpty
        }
        let transcriptURL = try XCTUnwrap(manager.lastSavedTranscriptURL)
        let values = try XCTUnwrap(try TranscriptFrontmatter.readValues(from: transcriptURL))

        XCTAssertEqual(values["duration"], "0:04", "meeting metadata should use the longest readable track, not a short mic placeholder")
    }

    func testSilentMicSavesSystemTranscriptAndRetainsBothOriginalTracks() async throws {
        let retainedAudioDirectory = tempDirectory
            .appendingPathComponent("transcripts", isDirectory: true)
            .appendingPathComponent("audio", isDirectory: true)
        let manager = makeManager(
            speechToText: MetadataStubSpeechToTextEngine(transcript: "Remote participant speaking."),
            diarization: MetadataStubDiarizationEngine(segments: singleSpeakerSegments(duration: 2.5)),
            retainedAudioDirectory: retainedAudioDirectory
        )
        let scratchDirectory = tempDirectory.appendingPathComponent("audio")
        let micURL = scratchDirectory.appendingPathComponent("silent-mic.wav")
        let systemURL = scratchDirectory.appendingPathComponent("system.wav")
        try writeMonoWAV(to: micURL, duration: 2.5, amplitude: 0)
        try writeMonoWAV(to: systemURL, duration: 2.5)

        manager.startTranscription(
            micURL: micURL,
            systemURL: systemURL,
            outputFolder: tempDirectory.appendingPathComponent("transcripts"),
            meetingTitle: "Partial microphone recovery"
        )

        try await waitUntil {
            manager.lastSavedTranscriptURL != nil && manager.activeTasks.isEmpty
        }

        XCTAssertTrue(manager.failedTranscriptionManager.failedTranscriptions.isEmpty)
        let transcriptURL = try XCTUnwrap(manager.lastSavedTranscriptURL)
        let markdown = try String(contentsOf: transcriptURL, encoding: .utf8)
        let values = try XCTUnwrap(try TranscriptFrontmatter.readValues(from: transcriptURL))
        XCTAssertEqual(values["sources"], "[system_audio]")
        XCTAssertEqual(values["capture_quality"], "degraded")
        XCTAssertEqual(values["microphone_audio_unusable"], "true")
        XCTAssertTrue(markdown.contains("Remote participant speaking."))
        XCTAssertTrue(markdown.contains("The microphone track was missing or could not be transcribed"))

        let retainedFiles = FileManager.default
            .enumerator(at: retainedAudioDirectory, includingPropertiesForKeys: nil)?
            .compactMap { $0 as? URL } ?? []
        XCTAssertTrue(retainedFiles.contains { $0.lastPathComponent == "microphone.wav" })
        XCTAssertTrue(retainedFiles.contains { $0.lastPathComponent == "system_audio.wav" })
    }

    func testCancelAllSuppressesLateTranscriptSaveAndFailedQueue() async throws {
        let speech = BlockingMetadataStubSpeechToTextEngine(transcript: "This should not be saved.")
        let diarization = MetadataStubDiarizationEngine(segments: [
            SpeakerSegment(
                speakerId: 1,
                startTime: 0,
                endTime: 2,
                embedding: [Float](repeating: 0.42, count: 256),
                qualityScore: 0.95
            )
        ])
        let statsStore = MetadataCapturingStatsStore()
        let manager = makeManager(speechToText: speech, diarization: diarization, statsStore: statsStore)
        let scratchDirectory = tempDirectory.appendingPathComponent("audio")
        let micURL = scratchDirectory.appendingPathComponent("cancel-mic.wav")
        let systemURL = scratchDirectory.appendingPathComponent("cancel-system.wav")
        let outputFolder = tempDirectory.appendingPathComponent("transcripts")
        try writeMonoWAV(to: micURL, duration: 2.5)
        try writeMonoWAV(to: systemURL, duration: 2.5)

        manager.startTranscription(
            micURL: micURL,
            systemURL: systemURL,
            outputFolder: outputFolder,
            meetingTitle: "Cancelled call"
        )

        try await waitUntil {
            speech.didStart
        }

        XCTAssertTrue(manager.hasPreservableActiveTranscriptionAudio)
        XCTAssertTrue(
            manager.hasActiveTranscriptionWorkRequiringQuitConfirmation,
            "live transcription should require quit confirmation before cancellation"
        )
        manager.cancelAll()
        XCTAssertFalse(FileManager.default.fileExists(atPath: micURL.path), "cancelled live mic scratch audio should be deleted")
        XCTAssertFalse(FileManager.default.fileExists(atPath: systemURL.path), "cancelled live system scratch audio should be deleted")
        XCTAssertEqual(
            manager.activeTasks.count,
            1,
            "a cancelled blocking model call must keep the single-flight gate occupied until it exits"
        )
        XCTAssertEqual(manager.activeCount, 1, "queued work must still observe the cancelling pipeline as occupied")
        XCTAssertEqual(manager.backgroundTaskCount, 1, "background occupancy must clear only after the model call exits")
        XCTAssertFalse(
            manager.hasPreservableActiveTranscriptionAudio,
            "cancelled occupancy must not promise that already-discarded audio can be saved on quit"
        )
        XCTAssertFalse(
            manager.hasActiveTranscriptionWorkRequiringQuitConfirmation,
            "intentionally cancelled occupancy must not revive the background-work quit prompt"
        )
        XCTAssertEqual(
            manager.preserveActiveTranscriptionsForShutdown(errorMessage: "App quit during cancellation"),
            0,
            "cancel then quit must not create a failed entry for audio that was already discarded"
        )
        speech.release()

        try await waitUntil {
            speech.didReturn
        }
        try await Task.sleep(nanoseconds: 100_000_000)

        let savedMarkdown = (try? FileManager.default.contentsOfDirectory(
            at: outputFolder,
            includingPropertiesForKeys: nil
        ))?.filter { $0.pathExtension == "md" } ?? []

        XCTAssertTrue(savedMarkdown.isEmpty, "cancelled transcription should not save a late transcript")
        XCTAssertNil(manager.lastSavedTranscriptURL, "cancelled transcription should not publish saved metadata")
        XCTAssertTrue(statsStore.recordedSessions.isEmpty, "cancelled transcription should not record stats for a deleted transcript")
        XCTAssertEqual(manager.failedTranscriptionManager.failedTranscriptions.count, 0, "cancelled transcription should not enter retry queue")
        XCTAssertEqual(manager.activeCount, 0)
        XCTAssertEqual(manager.backgroundTaskCount, 0)
        XCTAssertTrue(manager.activeTasks.isEmpty)
    }

    func testCancelAllAfterCommittedSideEffectsStillPublishesTranscript() async throws {
        let statsStore = CancellingOnRecordStatsStore()
        let manager = makeManager(
            speechToText: MetadataStubSpeechToTextEngine(transcript: "This should stay visible."),
            diarization: MetadataStubDiarizationEngine(),
            statsStore: statsStore
        )
        statsStore.onFirstRecord = {
            Task { @MainActor in
                manager.cancelAll()
            }
        }
        let scratchDirectory = tempDirectory.appendingPathComponent("audio")
        let micURL = scratchDirectory.appendingPathComponent("committed-cancel-mic.wav")
        let systemURL = scratchDirectory.appendingPathComponent("committed-cancel-system.wav")
        let outputFolder = tempDirectory.appendingPathComponent("transcripts")
        try writeMonoWAV(to: micURL, duration: 2.5)
        try writeMonoWAV(to: systemURL, duration: 2.5)

        manager.startTranscription(
            micURL: micURL,
            systemURL: systemURL,
            outputFolder: outputFolder,
            meetingTitle: "Committed cancel"
        )

        try await waitUntil(timeout: 3.0) {
            manager.lastSavedTranscriptURL != nil && manager.activeTasks.isEmpty
        }

        let transcriptURL = try XCTUnwrap(manager.lastSavedTranscriptURL)
        XCTAssertTrue(FileManager.default.fileExists(atPath: transcriptURL.path))
        XCTAssertEqual(manager.displayStatus, .transcriptSaved)
        XCTAssertEqual(statsStore.recordedSessions.count, 1)
        XCTAssertEqual(manager.activeCount, 0)
        XCTAssertEqual(manager.backgroundTaskCount, 0)
    }

}
