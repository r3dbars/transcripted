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

    /// Regression test for a Codex review finding on this PR: `preserveActiveTranscriptionsForShutdown()`
    /// followed by `cancelAll()` must still let a *committed* task's outcome win over the later
    /// `CancellationError` its own body eventually throws — exactly like the pre-refactor code,
    /// where `committedTranscriptTaskIds` and `preservedTaskIdsForShutdown` were independent `Set`s,
    /// so `cancelAll()`'s unconditional `preservedTaskIdsForShutdown.removeAll()` never touched the
    /// committed marker. The sequence: commit -> preserve-for-shutdown -> cancelAll() -> the task's
    /// body finally returns with `CancellationError` (because `preserve()` already called
    /// `task.cancel()`). The committed outcome must still be published as a failure (matching old
    /// behavior — see `finishCancelledTaskIfNeeded`'s committed-branch), not silently swallowed as
    /// "just a cancellation."
    func testShutdownPreservationThenCancelAllKeepsCommittedPrecedenceOverTheTasksOwnCancellation() async throws {
        let speech = BlockingMetadataStubSpeechToTextEngine(transcript: "Should never actually be saved.")
        let retainedAudioDirectory = tempDirectory
            .appendingPathComponent("transcripts", isDirectory: true)
            .appendingPathComponent("audio", isDirectory: true)
        let manager = makeManager(
            speechToText: speech,
            diarization: MetadataStubDiarizationEngine(segments: singleSpeakerSegments()),
            retainedAudioDirectory: retainedAudioDirectory
        )
        let taskId = UUID()
        let micURL = tempDirectory.appendingPathComponent("audio", isDirectory: true).appendingPathComponent("mic.wav")
        try writeMonoWAV(to: micURL, duration: 2.5)

        manager.startTranscription(
            taskId: taskId,
            micURL: micURL,
            systemURL: nil,
            outputFolder: tempDirectory.appendingPathComponent("transcripts")
        )
        try await waitUntil { speech.didStart }

        // Force the task into the committed state directly, the same way
        // `commitSavedTranscriptSideEffectsUnlessCancelled` would deep inside the real pipeline —
        // this test only needs the state-machine consequence, not a full pipeline run.
        manager.markTaskTranscriptCommitted(taskId: taskId)
        XCTAssertTrue(manager.hasActiveTranscriptionWorkRequiringQuitConfirmation, "a committed-but-still-occupying task still needs quit confirmation")

        let preserved = manager.preserveActiveTranscriptionsForShutdown(errorMessage: "shutting down")
        XCTAssertEqual(preserved, 1, "the task still owned audio at commit time, so it must be preserved")
        XCTAssertTrue(manager.activeTasks.isEmpty, "preservation evicts occupancy synchronously")
        XCTAssertEqual(manager.failedTranscriptionManager.failedTranscriptions.count, 1, "preservation should have persisted one failed-queue row already")

        // cancelAll() no longer finds this id in activeTasks (preserve() already evicted it), so
        // it only exercises its "sweep any leftover .preservedForShutdown markers" pass.
        manager.cancelAll()

        // preserve() already called task.cancel() on the underlying Task; the blocking engine
        // (unlike the uncooperative one used elsewhere in this file) checks Task.isCancelled and
        // throws CancellationError on its own within ~20ms, without needing speech.release().
        try await waitUntil(timeout: 3) { speech.sawCancellation }

        try await waitUntil(timeout: 3) {
            if case .failed = manager.displayStatus { return true }
            return false
        }
        guard case .failed(let message) = manager.displayStatus else {
            return XCTFail("committed must win over the task's own CancellationError, publishing a failure instead of being silently suppressed")
        }
        XCTAssertEqual(message, "Transcription failed")
    }

    /// Regression test for the second Codex review finding on this PR: `performRetry`'s manual
    /// success/failure cleanup now also clears `tasks[failedId]`, and that is a real behavior fix,
    /// not just tidying up an internal collection. A retry can keep its failed row alive (when
    /// speaker naming is still pending), so the *same* `failedId` can be retried again — and on
    /// the pre-refactor code, a stale `committedTranscriptTaskIds` entry from an earlier retry of
    /// that id would win over a later retry's own genuine cancellation, incorrectly publishing
    /// "Retry failed" instead of silently suppressing it. Proves the second retry of the same id
    /// is cleanly suppressed when cancelled before it ever commits.
    func testSecondRetryOfTheSameFailedIdIsCleanlySuppressedWhenCancelledBeforeCommit() async throws {
        let speech = TwoPhaseMetadataStubSpeechToTextEngine(firstTranscript: "Thanks for joining.")
        let diarization = MetadataStubDiarizationEngine(segments: singleSpeakerSegments())
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

        // First retry succeeds but keeps the failed row alive because speaker naming is still
        // pending (matching the setup in testRetryKeepsFailedMeetingWhenSpeakerNameFinalizationFails).
        // This is the retry whose commit must NOT leak into the second retry below.
        let firstRetryDidPublish = await manager.retryFailedTranscription(
            failedId: failedId,
            outputFolder: tempDirectory.appendingPathComponent("transcripts")
        )
        XCTAssertTrue(firstRetryDidPublish)
        XCTAssertNotNil(manager.speakerNamingRequest, "speaker naming should still be pending after the first retry")
        XCTAssertEqual(
            manager.failedTranscriptionManager.failedTranscriptions.map(\.id),
            [failedId],
            "the row must still exist so the same id can be retried again"
        )
        XCTAssertTrue(manager.activeTasks.isEmpty)

        // Second retry of the SAME id, run concurrently so it can be cancelled mid-flight.
        let secondRetryTask = Task { @MainActor in
            await manager.retryFailedTranscription(
                failedId: failedId,
                outputFolder: tempDirectory.appendingPathComponent("transcripts")
            )
        }

        try await waitUntil { speech.secondCallStarted }
        XCTAssertTrue(manager.hasActiveTranscriptionWorkRequiringQuitConfirmation, "second retry should be occupying the pipeline before cancellation")

        manager.cancelAll()

        let secondRetryDidPublish = await secondRetryTask.value
        XCTAssertFalse(secondRetryDidPublish, "a cleanly cancelled retry must never publish a transcript-saved outcome")

        try await waitUntil { manager.activeTasks.isEmpty }

        if case .failed(let message) = manager.displayStatus {
            XCTFail("a genuinely cancelled second retry must be suppressed, not surfaced as a failure (\"\(message)\")")
        }
        let currentError = manager.failedTranscriptionManager.failedTranscriptions.first(where: { $0.id == failedId })?.errorMessage
        XCTAssertNotEqual(
            currentError?.hasPrefix("Retry failed"),
            true,
            "a suppressed cancellation must not overwrite the failed row's error message with a spurious 'Retry failed'"
        )
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

/// Speech-to-text stub for `testSecondRetryOfTheSameFailedIdIsCleanlySuppressedWhenCancelledBeforeCommit`:
/// its first two `transcribeSegment` calls resolve immediately with a real transcript (modeling a
/// first retry that actually commits — the mic+system multichannel pipeline calls
/// `transcribeSegment` once per channel, system then mic, so a single successful retry consumes
/// two calls, not one); every call after that blocks, checking `Task.isCancelled` like
/// `BlockingMetadataStubSpeechToTextEngine`, so a second retry of the same failed id can be driven
/// into a real, cooperative cancellation. Getting this threshold wrong (e.g. blocking from the
/// second call onward) makes the *first* retry's own mic-channel call hang forever, well before
/// the test ever reaches its second-retry logic — that was the cause of this test's hang.
@available(macOS 14.0, *)
@MainActor
private final class TwoPhaseMetadataStubSpeechToTextEngine: SpeechToTextEngine {
    nonisolated let objectWillChange = ObservableObjectPublisher()
    var isReady = true
    private(set) var secondCallStarted = false
    private var callCount = 0
    private let firstTranscript: String
    /// Number of real `transcribeSegment` calls the first (successful) retry consumes before the
    /// second retry's own first call arrives. Defaults to 2: one system-channel call, one
    /// mic-channel call — matching `transcribeMultichannelPipeline`'s per-channel call order.
    private let callsBeforeBlocking: Int

    init(firstTranscript: String, callsBeforeBlocking: Int = 2) {
        self.firstTranscript = firstTranscript
        self.callsBeforeBlocking = callsBeforeBlocking
    }

    func initialize() async {
        isReady = true
    }

    func transcribeSegment(samples: [Float], source: AudioSource) async throws -> String {
        callCount += 1
        guard callCount > callsBeforeBlocking else {
            return firstTranscript
        }
        secondCallStarted = true
        while true {
            if Task.isCancelled {
                throw CancellationError()
            }
            try? await Task.sleep(nanoseconds: 20_000_000)
        }
    }

    func cleanup() {
        isReady = false
    }
}
