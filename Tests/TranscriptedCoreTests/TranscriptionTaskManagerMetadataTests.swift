import XCTest
import Combine
import AVFoundation
import FluidAudio
@testable import TranscriptedCore

@available(macOS 14.0, *)
@MainActor
final class TranscriptionTaskManagerMetadataTests: XCTestCase {
    private var tempDirectory: URL!

    override func setUpWithError() throws {
        tempDirectory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: tempDirectory, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        if let tempDirectory {
            try? FileManager.default.removeItem(at: tempDirectory)
        }
    }

    func testPopulateSavedMetadataReadsLargeFrontmatterBeyondInitialChunk() throws {
        let manager = makeManager()
        let transcriptURL = tempDirectory.appendingPathComponent("Call_2026-04-22.md")

        let filler = (0..<180)
            .map { "padding_\($0): \"\(String(repeating: "x", count: 20))\"" }
            .joined(separator: "\n")
        let content = """
        ---
        date: 2026-04-22
        \(filler)
        title: "Quarterly Planning Review"
        duration: "42:17"
        mic_speakers: 2
        system_speakers: 3
        ---

        # Meeting Recording
        """
        try content.write(to: transcriptURL, atomically: true, encoding: .utf8)

        manager.populateSavedMetadata(from: transcriptURL)

        XCTAssertEqual(manager.lastSavedTitle, "Quarterly Planning Review")
        XCTAssertEqual(manager.lastSavedDuration, "42:17")
        XCTAssertEqual(manager.lastSavedSpeakerCount, 5)
    }

    func testResolvedRetainedAudioDirectoryFollowsProvider() {
        var providerCallCount = 0
        var nextDirectory = tempDirectory.appendingPathComponent("first")
        let manager = makeManager(retainedAudioDirectoryProvider: {
            providerCallCount += 1
            return nextDirectory
        })

        XCTAssertEqual(manager.resolvedRetainedAudioDirectory(), tempDirectory.appendingPathComponent("first"))
        XCTAssertEqual(providerCallCount, 1, "resolver should call provider on each lookup")

        nextDirectory = tempDirectory.appendingPathComponent("second")
        XCTAssertEqual(manager.resolvedRetainedAudioDirectory(), tempDirectory.appendingPathComponent("second"),
                       "resolver should reflect provider changes between calls (e.g. user moves capture library)")
        XCTAssertEqual(providerCallCount, 2)
    }

    func testResolvedRetainedAudioDirectoryFallsBackToStaticValue() {
        let staticDirectory = tempDirectory.appendingPathComponent("static")
        let manager = makeManager(retainedAudioDirectory: staticDirectory)

        XCTAssertEqual(manager.resolvedRetainedAudioDirectory(), staticDirectory,
                       "embedders that pass only the static value should still get a valid resolver result")
    }

    func testPublishTranscriptSavedDoesNotStayFinishingWhenSpeakerReviewIsPending() throws {
        let manager = makeManager()
        let transcriptURL = tempDirectory.appendingPathComponent("Customer_Call.md")
        try """
        ---
        transcript_id: "00000000-0000-0000-0000-000000000321"
        title: "Customer Call"
        duration: "10:03"
        mic_speakers: 1
        system_speakers: 2
        ---

        # Meeting Recording
        """.write(to: transcriptURL, atomically: true, encoding: .utf8)
        manager.displayStatus = .finishing
        manager.speakerNamingRequest = SpeakerNamingRequest(
            speakers: [],
            transcriptURL: transcriptURL,
            transcriptId: UUID(),
            systemAudioURL: tempDirectory.appendingPathComponent("system.wav"),
            micAudioURL: nil,
            onComplete: { _ in }
        )

        manager.publishTranscriptSaved(from: transcriptURL)

        XCTAssertEqual(manager.displayStatus, .transcriptSaved)
        XCTAssertEqual(manager.lastSavedTranscriptId, UUID(uuidString: "00000000-0000-0000-0000-000000000321"))
        XCTAssertEqual(manager.lastSavedTitle, "Customer Call")
        XCTAssertEqual(manager.lastSavedDuration, "10:03")
        XCTAssertEqual(manager.lastSavedSpeakerCount, 3)
    }

    func testDeferPendingSpeakerNamingReviewCompletesWithReviewLater() {
        let manager = makeManager()
        var completedUpdates: [SpeakerNameUpdate]?
        manager.speakerNamingRequest = SpeakerNamingRequest(
            speakers: [],
            transcriptURL: tempDirectory.appendingPathComponent("call.md"),
            transcriptId: UUID(),
            systemAudioURL: tempDirectory.appendingPathComponent("system.wav"),
            micAudioURL: nil,
            onComplete: { updates in
                completedUpdates = updates
            }
        )

        XCTAssertTrue(manager.deferPendingSpeakerNamingReview(reason: "queued_transcription"))
        XCTAssertEqual(completedUpdates?.count, 0)
        XCTAssertNil(manager.speakerNamingRequest)
        XCTAssertFalse(manager.deferPendingSpeakerNamingReview(reason: "queued_transcription"))
    }

    func testQueuedSpeakerNamingRequestDoesNotReplaceActiveReview() {
        let manager = makeManager()
        let firstId = UUID()
        let secondId = UUID()

        manager.enqueueSpeakerNamingRequest(SpeakerNamingRequest(
            speakers: [],
            transcriptURL: tempDirectory.appendingPathComponent("first.md"),
            transcriptId: firstId,
            systemAudioURL: tempDirectory.appendingPathComponent("first-system.wav"),
            micAudioURL: nil,
            onComplete: { _ in }
        ))
        manager.enqueueSpeakerNamingRequest(SpeakerNamingRequest(
            speakers: [],
            transcriptURL: tempDirectory.appendingPathComponent("second.md"),
            transcriptId: secondId,
            systemAudioURL: tempDirectory.appendingPathComponent("second-system.wav"),
            micAudioURL: nil,
            onComplete: { _ in }
        ))

        XCTAssertEqual(manager.speakerNamingRequest?.transcriptId, firstId)
        XCTAssertEqual(manager.pendingSpeakerNamingRequests.map(\.transcriptId), [secondId])
    }

    func testStatusResetClearsSavedVisualWhileSpeakerReviewPendingButKeepsMetadata() async throws {
        let manager = makeManager()
        let transcriptURL = tempDirectory.appendingPathComponent("Customer_Call.md")
        try """
        ---
        transcript_id: "00000000-0000-0000-0000-000000000654"
        title: "Customer Call"
        duration: "12:34"
        mic_speakers: 1
        system_speakers: 1
        ---

        # Meeting Recording
        """.write(to: transcriptURL, atomically: true, encoding: .utf8)
        manager.speakerNamingRequest = SpeakerNamingRequest(
            speakers: [],
            transcriptURL: transcriptURL,
            transcriptId: UUID(),
            systemAudioURL: tempDirectory.appendingPathComponent("system.wav"),
            micAudioURL: nil,
            onComplete: { _ in }
        )

        manager.publishTranscriptSaved(from: transcriptURL)
        manager.scheduleStatusReset(delay: 0)

        try await waitUntil {
            if case .idle = manager.displayStatus { return true }
            return false
        }
        XCTAssertEqual(manager.lastSavedTranscriptId, UUID(uuidString: "00000000-0000-0000-0000-000000000654"))
        XCTAssertEqual(manager.lastSavedTitle, "Customer Call")
        XCTAssertNotNil(manager.speakerNamingRequest)
    }

    func testTranscriptionTaskCarriesCalendarMeetingTitle() {
        let task = TranscriptionTask(
            micURL: tempDirectory.appendingPathComponent("mic.wav"),
            systemURL: tempDirectory.appendingPathComponent("system.wav"),
            outputFolder: tempDirectory.appendingPathComponent("transcripts"),
            meetingTitle: "Customer Discovery Sync"
        )

        XCTAssertEqual(task.meetingTitle, "Customer Discovery Sync")
    }

    func testTranscriptFormatterWritesCalendarMeetingTitle() {
        let result = TranscriptionResult(
            micUtterances: [],
            systemUtterances: [
                TranscriptionUtterance(
                    start: 0,
                    end: 2,
                    channel: 1,
                    speakerId: 0,
                    persistentSpeakerId: nil,
                    matchSimilarity: nil,
                    transcript: "Thanks for joining."
                )
            ],
            duration: 2,
            processingTime: 0.5
        )

        let markdown = TranscriptSaver.formatTranscriptMarkdown(
            result: result,
            transcriptId: UUID(uuidString: "00000000-0000-0000-0000-000000000123")!,
            date: Date(timeIntervalSince1970: 0),
            meetingTitle: "Customer Discovery Sync"
        )

        XCTAssertTrue(markdown.contains("title: \"Customer Discovery Sync\""))
    }

    func testTranscriptFormatterUsesExplicitFormatOptionsForSourcesAndObsidianMetadata() throws {
        let originalObsidianDefault = UserDefaults.standard.object(forKey: "enableObsidianFormat")
        defer {
            if let originalObsidianDefault {
                UserDefaults.standard.set(originalObsidianDefault, forKey: "enableObsidianFormat")
            } else {
                UserDefaults.standard.removeObject(forKey: "enableObsidianFormat")
            }
        }
        UserDefaults.standard.set(true, forKey: "enableObsidianFormat")

        let result = TranscriptionResult(
            micUtterances: [],
            systemUtterances: [
                TranscriptionUtterance(
                    start: 0,
                    end: 2,
                    channel: 1,
                    speakerId: 0,
                    persistentSpeakerId: nil,
                    matchSimilarity: nil,
                    transcript: "Imported meeting audio."
                )
            ],
            duration: 2,
            processingTime: 0.5
        )

        let defaultMarkdown = TranscriptSaver.formatTranscriptMarkdown(
            result: result,
            transcriptId: UUID(),
            date: Date(timeIntervalSince1970: 0),
            formatOptions: TranscriptFormatOptions(audioSources: [.systemAudio])
        )
        let obsidianMarkdown = TranscriptSaver.formatTranscriptMarkdown(
            result: result,
            transcriptId: UUID(),
            date: Date(timeIntervalSince1970: 0),
            formatOptions: TranscriptFormatOptions(
                audioSources: [.systemAudio],
                includeObsidianMetadata: true
            )
        )

        XCTAssertTrue(defaultMarkdown.contains("sources: [system_audio]"))
        XCTAssertFalse(defaultMarkdown.contains("### Microphone"), "system-only imports should not claim a microphone source")
        XCTAssertFalse(defaultMarkdown.contains("\ntags:"), "Core formatting should not read UserDefaults directly")
        XCTAssertTrue(obsidianMarkdown.contains("\ntags:"), "embedders can still opt into Obsidian metadata explicitly")
    }

    func testStartTranscriptionRejectsMissingSystemAudioBeforeBackgroundWorkStarts() throws {
        let manager = makeManager()
        let micScratchDirectory = tempDirectory.appendingPathComponent("audio")
        try FileManager.default.createDirectory(at: micScratchDirectory, withIntermediateDirectories: true)
        let micURL = micScratchDirectory.appendingPathComponent("mic.wav")
        try writeMonoWAV(to: micURL, duration: 2.5)

        manager.startTranscription(
            micURL: micURL,
            systemURL: nil,
            outputFolder: tempDirectory.appendingPathComponent("transcripts")
        )

        XCTAssertEqual(manager.activeCount, 0)
        XCTAssertEqual(manager.backgroundTaskCount, 0)
        XCTAssertEqual(manager.activeTasks.count, 0)
        XCTAssertEqual(manager.failedTranscriptionManager.failedTranscriptions.count, 1)
        XCTAssertEqual(
            manager.failedTranscriptionManager.failedTranscriptions.first?.errorMessage,
            PipelineError.missingSystemAudio.localizedDescription
        )

        guard case .failed(let message) = manager.displayStatus else {
            return XCTFail("Expected failed display status when system audio is missing")
        }
        XCTAssertEqual(message, "System audio required")
    }

    func testMissingSystemAudioQueuesRetainedArchiveAndRemovesScratch() throws {
        let retainedAudioDirectory = tempDirectory
            .appendingPathComponent("transcripts", isDirectory: true)
            .appendingPathComponent("audio", isDirectory: true)
        let manager = makeManager(retainedAudioDirectory: retainedAudioDirectory)
        let micScratchDirectory = tempDirectory.appendingPathComponent("audio")
        try FileManager.default.createDirectory(at: micScratchDirectory, withIntermediateDirectories: true)
        let micURL = micScratchDirectory.appendingPathComponent("mic.wav")
        try writeMonoWAV(to: micURL, duration: 2.5)

        manager.startTranscription(
            micURL: micURL,
            systemURL: nil,
            outputFolder: tempDirectory.appendingPathComponent("transcripts")
        )

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

        manager.addFailedTranscriptionRetainingAudio(
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

    func testSystemOnlyFailedQueueCreatesPlaceholderAndRetainsSystemAudio() throws {
        let retainedAudioDirectory = tempDirectory
            .appendingPathComponent("transcripts", isDirectory: true)
            .appendingPathComponent("audio", isDirectory: true)
        let manager = makeManager(retainedAudioDirectory: retainedAudioDirectory)
        let scratchDirectory = tempDirectory.appendingPathComponent("audio")
        try FileManager.default.createDirectory(at: scratchDirectory, withIntermediateDirectories: true)
        let systemURL = scratchDirectory.appendingPathComponent("system.wav")
        try writeMonoWAV(to: systemURL, duration: 2.5)

        let didQueue = manager.addFailedTranscriptionRetainingAvailableAudio(
            micAudioURL: nil,
            systemAudioURL: systemURL,
            errorMessage: "Recording stopped without microphone audio."
        )

        XCTAssertTrue(didQueue)
        let failed = try XCTUnwrap(manager.failedTranscriptionManager.failedTranscriptions.first)
        XCTAssertTrue(failed.micAudioURL.lastPathComponent.contains("microphone_placeholder"))
        XCTAssertTrue(failed.micAudioURL.path.hasPrefix(retainedAudioDirectory.path + "/"))
        XCTAssertTrue(failed.systemAudioURL?.path.hasPrefix(retainedAudioDirectory.path + "/") ?? false)
        XCTAssertTrue(FileManager.default.fileExists(atPath: failed.micAudioURL.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: failed.systemAudioURL?.path ?? ""))
        XCTAssertFalse(FileManager.default.fileExists(atPath: systemURL.path), "scratch system audio should be removed after archive")
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
        let manager = makeManager(speechToText: speech, diarization: diarization)
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

        manager.cancelAll()
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
        XCTAssertEqual(manager.failedTranscriptionManager.failedTranscriptions.count, 0, "cancelled transcription should not enter retry queue")
        XCTAssertEqual(manager.activeCount, 0)
        XCTAssertEqual(manager.backgroundTaskCount, 0)
        XCTAssertTrue(manager.activeTasks.isEmpty)
    }

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
        let metadata = try XCTUnwrap(statsStore.recordedSessions.first)
        XCTAssertLessThan(
            abs(metadata.date.timeIntervalSince(sourceRecordingDate)),
            0.001,
            "recording metadata should use the source recording date"
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

    func testPipelineModelReadinessReloadsModelsAfterCleanup() async throws {
        let speech = MetadataStubSpeechToTextEngine(isReady: false)
        let diarization = MetadataStubDiarizationEngine(isReady: false)
        let manager = makeManager(speechToText: speech, diarization: diarization)

        try await manager.transcription.ensureModelsReadyForPipeline()

        XCTAssertTrue(speech.isReady)
        XCTAssertTrue(diarization.isReady)
        XCTAssertEqual(speech.initializeCallCount, 1)
        XCTAssertEqual(diarization.initializeCallCount, 1)

        speech.cleanup()
        diarization.cleanup()

        try await manager.transcription.ensureModelsReadyForPipeline()

        XCTAssertTrue(speech.isReady)
        XCTAssertTrue(diarization.isReady)
        XCTAssertEqual(speech.initializeCallCount, 2)
        XCTAssertEqual(diarization.initializeCallCount, 2)
    }

    func testSafeFailureDiagnosticMessageKeepsTypedRootCause() {
        XCTAssertEqual(
            TranscriptionTaskManager.safeFailureDiagnosticMessage(
                for: PipelineError.modelInferenceFailed(model: "Parakeet", underlying: "/Users/redbars/private/path")
            ),
            "Parakeet inference failed"
        )
        XCTAssertEqual(
            TranscriptionTaskManager.safeFailureDiagnosticMessage(
                for: PipelineError.saveFailed(detail: "/Users/redbars/private/transcript.md")
            ),
            "Failed to save transcript"
        )
        XCTAssertEqual(
            TranscriptionTaskManager.safeFailureDiagnosticMessage(
                for: PipelineError.unknown(underlying: "PyAnnote failed while reading /Users/redbars/audio.wav")
            ),
            "Diarization failed"
        )
        XCTAssertEqual(
            TranscriptionTaskManager.safeFailureDiagnosticMessage(
                for: PipelineError.unknown(underlying: "The operation couldn’t be completed. (com.apple.coreaudio.avfaudio error 2003334207.)")
            ),
            "Invalid audio format"
        )
        XCTAssertEqual(
            TranscriptionTaskManager.safeFailureDiagnosticMessage(
                for: PipelineError.noSpeechDetected
            ),
            "No speech detected"
        )
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

    private func makeManager(
        speechToText: (any SpeechToTextEngine)? = nil,
        diarization: (any DiarizationEngine)? = nil,
        retainedAudioDirectory: URL? = nil,
        retainedAudioDirectoryProvider: (() -> URL?)? = nil,
        statsStore: (any StatsStore)? = nil
    ) -> TranscriptionTaskManager {
        let paths = CoreStoragePaths(
            transcripts: tempDirectory.appendingPathComponent("transcripts"),
            speakerDB: tempDirectory.appendingPathComponent("speakers.sqlite"),
            statsDB: tempDirectory.appendingPathComponent("stats.sqlite"),
            failedQueue: tempDirectory.appendingPathComponent("failed_transcriptions.json"),
            speakerClips: tempDirectory.appendingPathComponent("speaker_clips"),
            audioCaptures: tempDirectory.appendingPathComponent("audio"),
            logs: tempDirectory.appendingPathComponent("logs")
        )

        try? FileManager.default.createDirectory(at: paths.transcripts, withIntermediateDirectories: true)
        try? FileManager.default.createDirectory(at: paths.audioCaptures, withIntermediateDirectories: true)
        try? FileManager.default.createDirectory(at: paths.speakerClips, withIntermediateDirectories: true)
        try? FileManager.default.createDirectory(at: paths.logs, withIntermediateDirectories: true)

        let resolvedSpeechToText = speechToText ?? MetadataStubSpeechToTextEngine()
        let resolvedDiarization = diarization ?? MetadataStubDiarizationEngine()

        return TranscriptionTaskManager(
            failedTranscriptionManager: FailedTranscriptionManager(paths: paths),
            speechToText: resolvedSpeechToText,
            diarization: resolvedDiarization,
            speakerStore: SpeakerDatabase(path: paths.speakerDB.path),
            speakerClipsDirectory: paths.speakerClips,
            cleanupDirectories: [paths.audioCaptures, paths.speakerClips],
            retainedAudioDirectory: retainedAudioDirectory,
            retainedAudioDirectoryProvider: retainedAudioDirectoryProvider,
            statsStore: statsStore
        )
    }

    private func writeMonoWAV(to url: URL, duration: TimeInterval, sampleRate: Double = 16_000) throws {
        let frameCount = Int(duration * sampleRate)
        guard let format = AVAudioFormat(
            commonFormat: .pcmFormatFloat32,
            sampleRate: sampleRate,
            channels: 1,
            interleaved: false
        ) else {
            return XCTFail("Failed to create test audio format")
        }

        let file = try AVAudioFile(
            forWriting: url,
            settings: format.settings,
            commonFormat: format.commonFormat,
            interleaved: format.isInterleaved
        )
        guard let buffer = AVAudioPCMBuffer(
            pcmFormat: format,
            frameCapacity: AVAudioFrameCount(frameCount)
        ) else {
            return XCTFail("Failed to create test audio buffer")
        }

        buffer.frameLength = AVAudioFrameCount(frameCount)
        if let channelData = buffer.floatChannelData?[0] {
            for index in 0..<frameCount {
                channelData[index] = 0.25
            }
        }

        try file.write(from: buffer)
    }

    private func waitUntil(
        timeout: TimeInterval = 2.0,
        condition: @escaping @MainActor () -> Bool
    ) async throws {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if condition() {
                return
            }
            try await Task.sleep(nanoseconds: 50_000_000)
        }
        XCTFail("Timed out waiting for condition")
    }

    private func localDate(
        year: Int,
        month: Int,
        day: Int,
        hour: Int,
        minute: Int,
        second: Int
    ) -> Date {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = .current
        return calendar.date(from: DateComponents(
            timeZone: .current,
            year: year,
            month: month,
            day: day,
            hour: hour,
            minute: minute,
            second: second
        ))!
    }

    private func frontmatterDateString(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd"
        return formatter.string(from: date)
    }

    private func frontmatterTimeString(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "HH:mm:ss"
        return formatter.string(from: date)
    }
}

@available(macOS 14.0, *)
private final class MetadataCapturingStatsStore: StatsStore {
    private let lock = NSLock()
    private var sessions: [RecordingMetadata] = []

    var recordedSessions: [RecordingMetadata] {
        lock.lock()
        defer { lock.unlock() }
        return sessions
    }

    func recordSession(_ metadata: RecordingMetadata) {
        lock.lock()
        sessions.append(metadata)
        lock.unlock()
    }

    func getTotalRecordingsCount() -> Int {
        recordedSessions.count
    }

    func getRecordings(from startDate: Date, to endDate: Date) -> [RecordingMetadata] {
        recordedSessions.filter { $0.date >= startDate && $0.date <= endDate }
    }

    func recordingExists(transcriptPath: String) -> Bool {
        recordedSessions.contains { $0.transcriptPath == transcriptPath }
    }
}

@available(macOS 14.0, *)
@MainActor
private final class MetadataStubSpeechToTextEngine: SpeechToTextEngine {
    nonisolated let objectWillChange = ObservableObjectPublisher()
    var isReady: Bool
    var initializeCallCount = 0
    private let transcript: String
    private let transcribeError: Error?

    init(isReady: Bool = true, transcript: String = "", transcribeError: Error? = nil) {
        self.isReady = isReady
        self.transcript = transcript
        self.transcribeError = transcribeError
    }

    func initialize() async {
        initializeCallCount += 1
        isReady = true
    }
    func transcribeSegment(samples: [Float], source: AudioSource) async throws -> String {
        if let transcribeError {
            throw transcribeError
        }
        return transcript
    }
    func cleanup() {
        isReady = false
    }
}

@available(macOS 14.0, *)
@MainActor
private final class BlockingMetadataStubSpeechToTextEngine: SpeechToTextEngine {
    nonisolated let objectWillChange = ObservableObjectPublisher()
    var isReady = true
    private(set) var didStart = false
    private(set) var didReturn = false
    private var shouldRelease = false
    private let transcript: String

    init(transcript: String) {
        self.transcript = transcript
    }

    func initialize() async {
        isReady = true
    }

    func transcribeSegment(samples: [Float], source: AudioSource) async throws -> String {
        didStart = true
        while !shouldRelease {
            try? await Task.sleep(nanoseconds: 20_000_000)
        }
        didReturn = true
        return transcript
    }

    func release() {
        shouldRelease = true
    }

    func cleanup() {
        isReady = false
    }
}

@available(macOS 14.0, *)
@MainActor
private final class MetadataStubDiarizationEngine: DiarizationEngine {
    nonisolated let objectWillChange = ObservableObjectPublisher()
    var isReady: Bool
    var initializeCallCount = 0
    private let segments: [SpeakerSegment]

    init(isReady: Bool = true, segments: [SpeakerSegment] = []) {
        self.isReady = isReady
        self.segments = segments
    }

    func initialize() async {
        initializeCallCount += 1
        isReady = true
    }
    func diarizeOffline(samples: [Float], sampleRate: Int) async throws -> [SpeakerSegment] { segments }
    func diarizeOffline(audioURL: URL) async throws -> [SpeakerSegment] { segments }
    func cleanup() {
        isReady = false
    }
}
