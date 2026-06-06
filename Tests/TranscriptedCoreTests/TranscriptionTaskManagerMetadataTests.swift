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

    func testSavedTranscriptOwnerSurvivesSpeakerReviewRewrite() throws {
        let manager = makeManager()
        let taskId = UUID()
        let transcriptId = UUID()
        let transcriptURL = tempDirectory.appendingPathComponent("Customer_Call.md")
        try """
        ---
        transcript_id: "\(transcriptId.uuidString)"
        title: "Customer Call"
        duration: "10:03"
        mic_speakers: 1
        system_speakers: 2
        ---

        # Meeting Recording
        """.write(to: transcriptURL, atomically: true, encoding: .utf8)

        manager.publishTranscriptSaved(from: transcriptURL, taskId: taskId)
        manager.populateSavedMetadata(from: transcriptURL)

        XCTAssertEqual(manager.lastSavedTranscriptTaskId, taskId)
    }

    func testSavedTranscriptOwnerSurvivesInterleavedSpeakerReviewRewrite() throws {
        let manager = makeManager()
        let firstTaskId = UUID()
        let secondTaskId = UUID()
        let firstTranscriptId = UUID()
        let secondTranscriptId = UUID()
        let firstURL = tempDirectory.appendingPathComponent("First_Call.md")
        let firstRenamedURL = tempDirectory.appendingPathComponent("First_Call_Named.md")
        let secondURL = tempDirectory.appendingPathComponent("Second_Call.md")

        try transcriptContent(id: firstTranscriptId, title: "First Call")
            .write(to: firstURL, atomically: true, encoding: .utf8)
        try transcriptContent(id: firstTranscriptId, title: "First Call")
            .write(to: firstRenamedURL, atomically: true, encoding: .utf8)
        try transcriptContent(id: secondTranscriptId, title: "Second Call")
            .write(to: secondURL, atomically: true, encoding: .utf8)

        manager.publishTranscriptSaved(from: firstURL, taskId: firstTaskId)
        manager.publishTranscriptSaved(from: secondURL, taskId: secondTaskId)
        manager.populateSavedMetadata(from: firstRenamedURL)

        XCTAssertEqual(manager.lastSavedTranscriptId, firstTranscriptId)
        XCTAssertEqual(manager.lastSavedTranscriptTaskId, firstTaskId)
    }

    func testPendingSpeakerNamingReviewTracksLastSavedTranscriptAcrossRename() throws {
        let manager = makeManager()
        let taskId = UUID()
        let transcriptId = UUID()
        let originalURL = tempDirectory.appendingPathComponent("Customer_Call.md")
        let renamedURL = tempDirectory.appendingPathComponent("Customer_Call_Named.md")
        let content = """
        ---
        transcript_id: "\(transcriptId.uuidString)"
        title: "Customer Call"
        duration: "10:03"
        mic_speakers: 1
        system_speakers: 2
        ---

        # Meeting Recording
        """
        try content.write(to: originalURL, atomically: true, encoding: .utf8)
        try content.write(to: renamedURL, atomically: true, encoding: .utf8)

        manager.publishTranscriptSaved(from: originalURL, taskId: taskId)
        manager.speakerNamingRequest = SpeakerNamingRequest(
            speakers: [],
            transcriptURL: originalURL,
            transcriptId: transcriptId,
            systemAudioURL: tempDirectory.appendingPathComponent("system.wav"),
            micAudioURL: nil,
            onComplete: { _ in }
        )
        manager.populateSavedMetadata(from: renamedURL)

        XCTAssertTrue(manager.hasPendingSpeakerNamingReviewForLastSavedTranscript())
        XCTAssertEqual(manager.lastSavedTranscriptTaskId, taskId)
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

    func testClearCompletedSpeakerNamingRequestClearsActiveReviewAndPromotesNext() {
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

        manager.clearCompletedSpeakerNamingRequest(transcriptId: firstId)

        XCTAssertEqual(manager.speakerNamingRequest?.transcriptId, secondId)
        XCTAssertTrue(manager.pendingSpeakerNamingRequests.isEmpty)
    }

    func testCancelSpeakerNamingRequestCleansArtifactsAndPromotesNext() throws {
        let manager = makeManager()
        let firstId = UUID()
        let secondId = UUID()
        let micURL = tempDirectory.appendingPathComponent("audio/first-mic.wav")
        let systemURL = tempDirectory.appendingPathComponent("audio/first-system.wav")
        let clipURL = tempDirectory.appendingPathComponent("speaker_clips/first-clip.wav")
        try Data("mic".utf8).write(to: micURL)
        try Data("system".utf8).write(to: systemURL)
        try Data("clip".utf8).write(to: clipURL)

        manager.enqueueSpeakerNamingRequest(SpeakerNamingRequest(
            speakers: [
                SpeakerNamingEntry(
                    id: UUID(),
                    diarizerSpeakerId: "1",
                    clipURL: clipURL,
                    sampleText: "hello",
                    currentName: nil,
                    matchSimilarity: nil,
                    needsNaming: true,
                    needsConfirmation: false
                )
            ],
            transcriptURL: tempDirectory.appendingPathComponent("first.md"),
            transcriptId: firstId,
            systemAudioURL: systemURL,
            micAudioURL: micURL,
            shouldRemoveTemporaryAudioOnCleanup: true,
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

        manager.cancelSpeakerNamingRequest(transcriptId: firstId)

        XCTAssertEqual(manager.speakerNamingRequest?.transcriptId, secondId)
        XCTAssertTrue(manager.pendingSpeakerNamingRequests.isEmpty)
        XCTAssertFalse(FileManager.default.fileExists(atPath: micURL.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: systemURL.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: clipURL.path))
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

        manager.cancelAll()
        XCTAssertFalse(FileManager.default.fileExists(atPath: micURL.path), "cancelled live mic scratch audio should be deleted")
        XCTAssertFalse(FileManager.default.fileExists(atPath: systemURL.path), "cancelled live system scratch audio should be deleted")
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
        XCTAssertEqual(statsStore.recordedSessions.count, 1, "successful imports should record stats exactly once")
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

    private func transcriptContent(id: UUID, title: String) -> String {
        """
        ---
        transcript_id: "\(id.uuidString)"
        title: "\(title)"
        duration: "10:03"
        mic_speakers: 1
        system_speakers: 2
        ---

        # Meeting Recording
        """
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
private final class CancellingOnRecordStatsStore: StatsStore {
    private let base = MetadataCapturingStatsStore()
    private let lock = NSLock()
    private var didCallOnFirstRecord = false
    var onFirstRecord: (() -> Void)?

    var recordedSessions: [RecordingMetadata] {
        base.recordedSessions
    }

    func recordSession(_ metadata: RecordingMetadata) {
        base.recordSession(metadata)

        let callback: (() -> Void)?
        lock.lock()
        if didCallOnFirstRecord {
            callback = nil
        } else {
            didCallOnFirstRecord = true
            callback = onFirstRecord
        }
        lock.unlock()
        callback?()
    }

    func getTotalRecordingsCount() -> Int {
        base.getTotalRecordingsCount()
    }

    func getRecordings(from startDate: Date, to endDate: Date) -> [RecordingMetadata] {
        base.getRecordings(from: startDate, to: endDate)
    }

    func recordingExists(transcriptPath: String) -> Bool {
        base.recordingExists(transcriptPath: transcriptPath)
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
