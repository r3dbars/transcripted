import XCTest
@testable import TranscriptedCore

/// Companion to `PipelineRollbackRegistryTests.swift`. That file drives the register* helpers
/// directly against fixture files — real production code, but no real `TranscriptionTaskManager`
/// behind it. This file covers the two scenarios that genuinely need one:
///
///  - Checkpoint 6 (dequeuing a just-queued speaker naming request) mutates manager-owned queue
///    state and triggers `cancelSpeakerNamingRequest`'s own clip cleanup — a recorder stand-in
///    can't catch a regression in that wiring, only a real `enqueueSpeakerNamingRequest` /
///    `cancelSpeakerNamingRequest` round trip can.
///  - The "superseded task" rollback branch inside `commitSavedTranscriptSideEffectsUnlessCancelled`
///    triggers on `canCommitTaskSideEffects(taskId:)` returning false, which is not a
///    `Task.checkCancellation()` throw — a separate trigger path worth proving separately from
///    the Task-cancellation path already covered generically.
///
/// Declared as an extension on `TranscriptionTaskManagerMetadataTests` (matching
/// `TranscriptionTaskManagerImportedAudioTests.swift`) to reuse its `makeManager()` fixture and
/// `tempDirectory` instead of re-implementing manager construction here.
@available(macOS 14.0, *)
@MainActor
extension TranscriptionTaskManagerMetadataTests {

    /// Mirrors the real `transcribeMultichannelPipeline` registration for checkpoint 6 exactly:
    /// a strong `manager` local captured (not `[weak self]`) into `rollback.register { await
    /// manager.cancelSpeakerNamingRequest(transcriptId:) }`. Asserts the queued request is
    /// genuinely dequeued (not just that some closure ran) and that `cancelSpeakerNamingRequest`'s
    /// own clip cleanup fires as a side effect, exactly as it would after a real cancellation.
    func testRealDequeueRollbackCancelsQueuedSpeakerNamingRequestAndItsOwnClipCleanup() async throws {
        let manager = makeManager()
        let transcriptId = UUID()
        let savedURL = tempDirectory.appendingPathComponent("transcripts").appendingPathComponent("Dequeue_Call.md")
        try Data("transcript".utf8).write(to: savedURL)

        // cancelSpeakerNamingRequest's own cleanup only deletes files under a managed cleanup
        // directory (a safety guard against deleting arbitrary paths) — the same directory real
        // clip extraction always writes to — so this clip must live there for that assertion to
        // mean anything.
        let clipURL = manager.transcription.speakerClipsDirectory.appendingPathComponent("system_speaker_0.caf")
        try Data("clip".utf8).write(to: clipURL)

        let entry = SpeakerNamingEntry(
            id: UUID(),
            diarizerSpeakerId: "0",
            channel: .system,
            clipURL: clipURL,
            sampleText: "hello there",
            currentName: nil,
            matchSimilarity: nil,
            needsNaming: true,
            needsConfirmation: false
        )
        manager.enqueueSpeakerNamingRequest(SpeakerNamingRequest(
            speakers: [entry],
            transcriptURL: savedURL,
            transcriptId: transcriptId,
            systemAudioURL: tempDirectory.appendingPathComponent("system.wav"),
            micAudioURL: nil,
            shouldRemoveTemporaryAudioOnCleanup: false,
            onComplete: { _ in }
        ))
        XCTAssertNotNil(manager.speakerNamingRequest, "request should be queued before rollback runs")

        let rollback = PipelineRollbackRegistry()
        TranscriptionTaskManager.registerSavedTranscriptRollback(savedURL: savedURL, replacementTranscriptRollback: nil, into: rollback)
        // The exact production pattern from transcribeMultichannelPipeline: snapshot a strong
        // local before the actor hop, not [weak self].
        rollback.register {
            await manager.cancelSpeakerNamingRequest(transcriptId: transcriptId)
        }

        await rollback.rollbackAll()

        XCTAssertNil(manager.speakerNamingRequest, "rollback should dequeue the request via the real coordinator method")
        XCTAssertFalse(FileManager.default.fileExists(atPath: savedURL.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: clipURL.path), "cancelSpeakerNamingRequest's own cleanupSpeakerClips should remove the clip")
    }

    /// Full six-checkpoint shape against a real manager and real files: transcript, retained
    /// audio, both channels' clips, and a queued naming request that gets dequeued. Complements
    /// the file-only checkpoints 1-4 covered in `PipelineRollbackRegistryTests.swift` by proving
    /// the whole chain converges to a clean final state when a live manager is involved too.
    func testRealCheckpointSixSequenceCleansEveryArtifactAndDequeuesTheRequest() async throws {
        let manager = makeManager()
        let transcriptId = UUID()

        let savedURL = tempDirectory.appendingPathComponent("transcripts").appendingPathComponent("Full_Sequence.md")
        try Data("transcript".utf8).write(to: savedURL)

        let audioDirectory = tempDirectory.appendingPathComponent("audio", isDirectory: true)
            .appendingPathComponent("Full_Sequence_audio", isDirectory: true)
        try FileManager.default.createDirectory(at: audioDirectory, withIntermediateDirectories: true)
        let micAudioURL = audioDirectory.appendingPathComponent("microphone.wav")
        let systemAudioURL = audioDirectory.appendingPathComponent("system_audio.wav")
        try Data("mic".utf8).write(to: micAudioURL)
        try Data("system".utf8).write(to: systemAudioURL)

        let clipsDirectory = manager.transcription.speakerClipsDirectory
        let systemClipURL = clipsDirectory.appendingPathComponent("full_system_speaker_0.caf")
        let micClipURL = clipsDirectory.appendingPathComponent("full_mic_speaker_0.caf")
        try Data("system clip".utf8).write(to: systemClipURL)
        try Data("mic clip".utf8).write(to: micClipURL)

        let rollback = PipelineRollbackRegistry()
        TranscriptionTaskManager.registerSavedTranscriptRollback(savedURL: savedURL, replacementTranscriptRollback: nil, into: rollback)
        TranscriptionTaskManager.registerRetainedAudioRollback(directory: audioDirectory, urls: [micAudioURL, systemAudioURL], into: rollback)
        TranscriptionTaskManager.registerSpeakerClipsRollback([systemClipURL], channel: "system", into: rollback)
        TranscriptionTaskManager.registerSpeakerClipsRollback([micClipURL], channel: "mic", into: rollback)

        let entry = SpeakerNamingEntry(
            id: UUID(),
            diarizerSpeakerId: "0",
            channel: .system,
            clipURL: systemClipURL,
            sampleText: "hello there",
            currentName: nil,
            matchSimilarity: nil,
            needsNaming: true,
            needsConfirmation: false
        )
        manager.enqueueSpeakerNamingRequest(SpeakerNamingRequest(
            speakers: [entry],
            transcriptURL: savedURL,
            transcriptId: transcriptId,
            systemAudioURL: systemAudioURL,
            micAudioURL: micAudioURL,
            shouldRemoveTemporaryAudioOnCleanup: false,
            onComplete: { _ in }
        ))
        rollback.register {
            await manager.cancelSpeakerNamingRequest(transcriptId: transcriptId)
        }
        XCTAssertNotNil(manager.speakerNamingRequest)

        await rollback.rollbackAll()

        XCTAssertNil(manager.speakerNamingRequest)
        XCTAssertFalse(FileManager.default.fileExists(atPath: savedURL.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: micAudioURL.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: systemAudioURL.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: audioDirectory.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: systemClipURL.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: micClipURL.path))
    }

    /// `canCommitTaskSideEffects(taskId:)` returning false — because `taskId` was never (or is no
    /// longer) in `activeTasks` — is a distinct trigger from `Task.checkCancellation()` throwing,
    /// but `commitSavedTranscriptSideEffectsUnlessCancelled` routes both through the same
    /// `rollback.rollbackAll()`. Prove the superseded path for real: the ambient Task here is
    /// never cancelled, only `taskId` is deliberately kept out of `activeTasks`.
    func testSupersededTaskRollsBackThroughRealCommitSavedTranscriptSideEffectsUnlessCancelled() async throws {
        let manager = makeManager()
        let taskId = UUID()
        let transcriptId = UUID()

        let savedURL = tempDirectory.appendingPathComponent("transcripts").appendingPathComponent("Superseded_Call.md")
        try Data("transcript".utf8).write(to: savedURL)
        let audioDirectory = tempDirectory.appendingPathComponent("audio", isDirectory: true)
            .appendingPathComponent("Superseded_Call_audio", isDirectory: true)
        try FileManager.default.createDirectory(at: audioDirectory, withIntermediateDirectories: true)
        let micAudioURL = audioDirectory.appendingPathComponent("microphone.wav")
        try Data("mic".utf8).write(to: micAudioURL)

        let rollback = PipelineRollbackRegistry()
        TranscriptionTaskManager.registerSavedTranscriptRollback(savedURL: savedURL, replacementTranscriptRollback: nil, into: rollback)
        TranscriptionTaskManager.registerRetainedAudioRollback(directory: audioDirectory, urls: [micAudioURL], into: rollback)

        XCTAssertFalse(Task.isCancelled, "this scenario must be distinguishable from the Task-cancellation path")
        XCTAssertNil(manager.activeTasks[taskId], "taskId is deliberately absent — this is what makes canCommitTaskSideEffects return false")

        do {
            try await manager.commitSavedTranscriptSideEffectsUnlessCancelled(
                taskId: taskId,
                savedURL: savedURL,
                result: TranscriptionResult(micUtterances: [], systemUtterances: [], duration: 1, processingTime: 0.1),
                transcriptId: transcriptId,
                meetingTitle: nil,
                transcriptDate: Date(),
                notifier: nil,
                rollback: rollback
            )
            XCTFail("Expected the superseded branch to throw CancellationError")
        } catch is CancellationError {
            // Expected — this helper has always thrown here, cancelled Task or not.
        }

        XCTAssertFalse(FileManager.default.fileExists(atPath: savedURL.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: micAudioURL.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: audioDirectory.path))
    }
}
