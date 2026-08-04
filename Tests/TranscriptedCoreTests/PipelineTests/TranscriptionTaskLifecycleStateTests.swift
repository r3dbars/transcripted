import XCTest
import Combine
import AVFoundation
import FluidAudio
@testable import TranscriptedCore

/// Coverage for `TranscriptionTaskManager`'s internal task-lifecycle map (`TaskLifecycleState`),
/// which replaced four collections that used to be updated in lockstep by the same `UUID`
/// (`activeTaskAudio`, `preservedTaskIdsForShutdown`, `intentionallyCancelledTaskIds`,
/// `committedTranscriptTaskIds`). `TaskLifecycleState` itself is `private`, so these tests drive
/// it the same way the rest of this file's siblings do: through the manager's real internal
/// methods and observable published state, not through `@testable` access to the enum.
///
/// Declared as an extension on `TranscriptionTaskManagerMetadataTests` (matching
/// `TranscriptionTaskManagerImportedAudioTests.swift` and
/// `PipelineRollbackRegistryManagerTests.swift`) to reuse its `makeManager()` fixture,
/// `tempDirectory`, and `waitUntil` helper.
@available(macOS 14.0, *)
@MainActor
extension TranscriptionTaskManagerMetadataTests {

    /// `cancel-during-running`, and the "deferred CoreML cancellation" scenario the old
    /// `cancelAll()` comments called out explicitly ("CoreML calls are not guaranteed to observe
    /// cancellation immediately"): the underlying engine here never checks `Task.isCancelled` and
    /// returns a real, successful transcript even after `cancelAll()` ran. The manager must still
    /// suppress that late result — the `.cancelling` marker set synchronously by `cancelAll()`,
    /// not the engine noticing cancellation, is what makes suppression happen.
    func testCancelDuringRunningSuppressesLateResultFromAnUncooperativeEngine() async throws {
        let speech = UncooperativeMetadataStubSpeechToTextEngine(transcript: "Should never be published.")
        let manager = makeManager(
            speechToText: speech,
            diarization: MetadataStubDiarizationEngine(segments: singleSpeakerSegments())
        )
        let micURL = tempDirectory.appendingPathComponent("audio", isDirectory: true).appendingPathComponent("mic.wav")
        try writeMonoWAV(to: micURL, duration: 2.5)

        manager.startTranscription(
            micURL: micURL,
            systemURL: nil,
            outputFolder: tempDirectory.appendingPathComponent("transcripts")
        )

        try await waitUntil { speech.didStart }

        XCTAssertTrue(manager.hasActiveTranscriptionWorkRequiringQuitConfirmation)

        manager.cancelAll()

        // The occupancy map still holds the task right after cancelAll() returns — CoreML work
        // is not guaranteed to observe cancellation immediately, so the task stays counted until
        // its body actually exits — but quit-confirmation must already reflect the cancel request.
        XCTAssertFalse(manager.activeTasks.isEmpty, "cancelled task must stay in the occupancy map until its body exits")
        XCTAssertFalse(manager.hasActiveTranscriptionWorkRequiringQuitConfirmation)
        XCTAssertFalse(manager.hasPreservableActiveTranscriptionAudio, "cancelAll() must have discarded the scratch-audio record")

        // Now let the uncooperative engine "finish" anyway — it never threw CancellationError.
        speech.release()

        try await waitUntil { manager.activeTasks.isEmpty }

        XCTAssertNil(manager.lastSavedTranscriptURL, "a late result from a task marked cancelling must never publish as saved")
        if case .failed = manager.displayStatus {
            XCTFail("a suppressed cancellation must not surface as a user-visible failure either")
        }
    }

    /// `.cancellingCommitted`: reachable, not merely theoretical. `cancelAll()` marks every
    /// occupied task cancelled without checking commit state first, so a task whose transcript
    /// already committed (this test drives the real `commitSavedTranscriptSideEffectsUnlessCancelled`
    /// directly, exactly as `PipelineRollbackRegistryManagerTests` does for the "superseded task"
    /// scenario) can still get the cancel marker. Two things must hold: quit-confirmation drops
    /// immediately (matching old behavior, which never special-cased a committed task in that
    /// check), and a *second* attempt to commit the same task afterward is rejected — proving
    /// `canCommitTaskSideEffects` treats `.cancellingCommitted` as cancelling, same as `.cancelling`.
    func testCancelAllRacingAnAlreadyCommittedTaskDropsQuitConfirmationAndRejectsALaterCommit() async throws {
        let manager = makeManager()
        let taskId = UUID()
        let transcriptId = UUID()

        let savedURL = tempDirectory.appendingPathComponent("transcripts").appendingPathComponent("Committed_Call.md")
        try Data("transcript".utf8).write(to: savedURL)

        manager.activeTasks[taskId] = Task {}
        defer {
            manager.activeTasks[taskId]?.cancel()
            manager.activeTasks.removeValue(forKey: taskId)
        }

        let firstRollback = PipelineRollbackRegistry()
        TranscriptionTaskManager.registerSavedTranscriptRollback(savedURL: savedURL, replacementTranscriptRollback: nil, into: firstRollback)
        try await manager.commitSavedTranscriptSideEffectsUnlessCancelled(
            taskId: taskId,
            savedURL: savedURL,
            result: TranscriptionResult(micUtterances: [], systemUtterances: [], duration: 1, processingTime: 0.1),
            transcriptId: transcriptId,
            meetingTitle: nil,
            transcriptDate: Date(),
            notifier: nil,
            rollback: firstRollback
        )
        XCTAssertTrue(manager.hasActiveTranscriptionWorkRequiringQuitConfirmation, "a committed-but-still-occupying task still needs quit confirmation")

        manager.cancelAll()

        XCTAssertFalse(
            manager.hasActiveTranscriptionWorkRequiringQuitConfirmation,
            "cancelAll() must mark even an already-committed task cancelled, matching the pre-refactor behavior"
        )

        let secondRollback = PipelineRollbackRegistry()
        TranscriptionTaskManager.registerSavedTranscriptRollback(savedURL: savedURL, replacementTranscriptRollback: nil, into: secondRollback)
        do {
            try await manager.commitSavedTranscriptSideEffectsUnlessCancelled(
                taskId: taskId,
                savedURL: savedURL,
                result: TranscriptionResult(micUtterances: [], systemUtterances: [], duration: 1, processingTime: 0.1),
                transcriptId: transcriptId,
                meetingTitle: nil,
                transcriptDate: Date(),
                notifier: nil,
                rollback: secondRollback
            )
            XCTFail("a commit attempt after cancelAll() raced the task should be rejected")
        } catch is CancellationError {
            // Expected: canCommitTaskSideEffects must see the cancelling marker even though the
            // task was already committed once.
        }
    }

    /// `shutdown-preservation`: `preserveActiveTranscriptionsForShutdown()` only ever preserves
    /// tasks that actually own scratch audio (the old code keyed this off `activeTaskAudio`,
    /// never `activeTasks`). A saved-audio-retranscription task — reusing already-retained files,
    /// so it was never entered into that audio map — must be left completely untouched by a
    /// shutdown sweep: still occupying, still running, nothing preserved.
    func testShutdownPreservationIgnoresAnAudioLessRetranscriptionTask() async throws {
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

        try await waitUntil { speech.didStart }

        let preserved = manager.preserveActiveTranscriptionsForShutdown(errorMessage: "shutting down")

        XCTAssertEqual(preserved, 0, "there is no scratch audio to preserve for a saved-audio retranscription")
        XCTAssertEqual(manager.activeTasks.count, 1, "an audio-less task must be left running, not evicted, by a shutdown sweep that found nothing to preserve")
        XCTAssertTrue(manager.failedTranscriptionManager.failedTranscriptions.isEmpty)

        speech.release()
        try await waitUntil {
            manager.lastSavedTranscriptURL != nil && manager.activeTasks.isEmpty
        }
        XCTAssertTrue(manager.failedTranscriptionManager.failedTranscriptions.isEmpty, "the retranscription should have completed normally, unaffected by the earlier no-op shutdown sweep")
    }

    /// `completion-during-cancelling` from the other direction: shutdown preservation evicts the
    /// task from the occupancy map and the preservable-audio surface *synchronously*, in the same
    /// call, even though the underlying engine has not yet noticed its `task.cancel()` call. Both
    /// published surfaces the app polls before quitting must already read as "nothing active."
    func testShutdownPreservationEvictsOccupancySynchronouslyBeforeTheEngineNoticesCancellation() async throws {
        let speech = UncooperativeMetadataStubSpeechToTextEngine(transcript: "Should still be preserved as failed audio.")
        let retainedAudioDirectory = tempDirectory
            .appendingPathComponent("transcripts", isDirectory: true)
            .appendingPathComponent("audio", isDirectory: true)
        let manager = makeManager(
            speechToText: speech,
            diarization: MetadataStubDiarizationEngine(segments: singleSpeakerSegments()),
            retainedAudioDirectory: retainedAudioDirectory
        )
        let micURL = tempDirectory.appendingPathComponent("audio", isDirectory: true).appendingPathComponent("mic.wav")
        try writeMonoWAV(to: micURL, duration: 2.5)

        manager.startTranscription(
            micURL: micURL,
            systemURL: nil,
            outputFolder: tempDirectory.appendingPathComponent("transcripts")
        )
        try await waitUntil { speech.didStart }
        XCTAssertTrue(manager.hasPreservableActiveTranscriptionAudio)

        let preserved = manager.preserveActiveTranscriptionsForShutdown(errorMessage: "shutting down")

        XCTAssertEqual(preserved, 1)
        // Synchronous, even though `speech` is still blocked mid-`transcribeSegment` and has not
        // observed cancellation at all (it never checks `Task.isCancelled`).
        XCTAssertTrue(manager.activeTasks.isEmpty)
        XCTAssertEqual(manager.activeCount, 0)
        XCTAssertFalse(manager.hasPreservableActiveTranscriptionAudio)
        XCTAssertFalse(manager.hasActiveTranscriptionWorkRequiringQuitConfirmation)

        speech.release()
        // The still-running task body eventually returns and must quietly clean itself up via
        // the `.preservedForShutdown` marker instead of publishing a second, redundant outcome.
        try await Task.sleep(nanoseconds: 200_000_000)
        XCTAssertEqual(manager.failedTranscriptionManager.failedTranscriptions.count, 1, "shutdown preservation should have persisted exactly one failed-queue row")
    }
}

/// Speech-to-text stub that models "CoreML calls are not guaranteed to observe cancellation
/// immediately" literally: unlike `BlockingMetadataStubSpeechToTextEngine`, it never checks
/// `Task.isCancelled` while blocked, so it returns a real, successful transcript even after the
/// owning `Task` was cancelled. Only `TaskLifecycleState`'s explicit cancel/preserve markers —
/// not engine-side cancellation checks — can suppress a result from an engine shaped like this.
@available(macOS 14.0, *)
@MainActor
private final class UncooperativeMetadataStubSpeechToTextEngine: SpeechToTextEngine {
    nonisolated let objectWillChange = ObservableObjectPublisher()
    var isReady = true
    private(set) var didStart = false
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
        return transcript
    }

    func release() {
        shouldRelease = true
    }

    func cleanup() {
        isReady = false
    }
}
