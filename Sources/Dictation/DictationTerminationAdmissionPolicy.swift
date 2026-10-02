import Foundation

/// A settled stop is not proof that its recovery WAV was written successfully.
/// While finalization is still active, only an existing WAV permits the
/// preserving-cancel fallback. Once inactive, retained native audio without a
/// WAV still blocks Quit; a completed save or explicit discard has neither.
enum DictationTerminationAdmissionPolicy {
    static func mustStopBeforeInference(snapshotAvailable: Bool, hasRecoverableRecording: Bool) -> Bool {
        !snapshotAvailable && hasRecoverableRecording
    }

    static func blocksNewCapture(hasRecoverableRecording: Bool, recoveryWAVExists: Bool) -> Bool {
        hasRecoverableRecording && !recoveryWAVExists
    }

    static func canTerminate(
        isDictating: Bool,
        checkpointSettled: Bool,
        hasRecoverableRecording: Bool,
        recoveryWAVExists: Bool
    ) -> Bool {
        if isDictating {
            return checkpointSettled && recoveryWAVExists
        }
        return recoveryWAVExists || !hasRecoverableRecording
    }

    static func canRetrySaving(
        isDictating: Bool,
        checkpointSettled: Bool,
        hasRecoverableRecording: Bool,
        recoveryWAVExists: Bool,
        isCurrentSession: Bool,
        hasPendingStart: Bool
    ) -> Bool {
        !isDictating && checkpointSettled && hasRecoverableRecording
            && !recoveryWAVExists && isCurrentSession && !hasPendingStart
    }
}

/// Quit while dictating. Stop the take and give it a few seconds to finish;
/// if it's still going, wait (bounded) for its recovery WAV. Without a settled
/// checkpoint and a real WAV, Quit is refused before anything cancels the
/// in-flight audio, so the only copy is never thrown away.
/// `DictationSessionController.finishDictationForTermination` runs this with
/// the real session; `Tests/DictationTerminationCheckpointTests.swift` runs it
/// with fakes.
@MainActor
enum DictationTerminationFinisher {
    static let unsafeQuitMessage =
        "Quit paused. Audio isn't saved yet; your recording wasn't discarded. Try Quit again shortly."
    static let uncheckpointedQuitMessage =
        "Quit paused. This recording isn't safely saved. Keep Transcripted open until dictation finishes."

    struct Steps {
        /// Set while Quit is admitted, so nothing queues a new take during
        /// shutdown. Every refusal clears it.
        var setTerminating: @MainActor (Bool) -> Void
        var dropQueuedStart: @MainActor () -> Void
        var isDictating: @MainActor () -> Bool
        /// Quit with no take running: blocked only by retained audio with no WAV.
        var admitInactiveQuit: @MainActor () -> Bool
        var stop: @MainActor () -> Void
        /// How many grace polls to give the normal stop.
        var gracePolls: Int
        /// One grace poll; false when the wait was cancelled.
        var sleepOnePoll: @MainActor () async -> Bool
        /// Marks the current take's stopped audio to be kept.
        var preserveStoppedAudio: @MainActor () -> Void
        /// Bounded wait for the checkpoint; false if there is none or it timed out.
        var waitForCheckpoint: @MainActor () async -> Bool
        /// After the checkpoint settles: does the current take have a real WAV?
        var canTerminateActive: @MainActor () -> Bool
        var showError: @MainActor (String) -> Void
        var cancelPreservingStoppedAudio: @MainActor () -> Void
    }

    static func run(_ steps: Steps) async -> Bool {
        steps.setTerminating(true)
        steps.dropQueuedStart()
        guard steps.isDictating() else { return steps.admitInactiveQuit() }
        steps.stop()

        for _ in 0..<steps.gracePolls {
            if !steps.isDictating() { return steps.admitInactiveQuit() }
            guard await steps.sleepOnePoll() else {
                steps.setTerminating(false)
                return false
            }
        }

        if steps.isDictating() {
            steps.preserveStoppedAudio()
            guard await steps.waitForCheckpoint() else {
                steps.showError(unsafeQuitMessage)
                steps.setTerminating(false)
                return false
            }
            guard steps.canTerminateActive() else {
                steps.showError(uncheckpointedQuitMessage)
                steps.setTerminating(false)
                return false
            }
            steps.cancelPreservingStoppedAudio()
        }
        return true
    }
}

/// Retry Saving for a take whose recovery WAV failed while its audio is still
/// in memory. Waits for the old stop to settle before readmitting the same
/// take, then runs it through the normal stop pipeline without pasting.
@MainActor
enum DictationRetainedAudioRetry {
    struct Steps {
        /// Bounded wait for the old checkpoint; false if it timed out.
        var waitForCheckpoint: @MainActor () async -> Bool
        var onCheckpointTimeout: @MainActor () -> Void
        /// `DictationTerminationAdmissionPolicy.canRetrySaving` on live state.
        var canRetry: @MainActor () -> Bool
        var resetStopGate: @MainActor () -> Void
        /// Puts the take back in the listening state the stop pipeline admits.
        var readmit: @MainActor () -> Void
        /// The stop pipeline, with no paste.
        var stopWithoutPaste: @MainActor () -> Void
        var afterStop: @MainActor () -> Void
    }

    static func run(_ steps: Steps) async {
        guard await steps.waitForCheckpoint() else {
            steps.onCheckpointTimeout()
            return
        }
        guard steps.canRetry() else { return }
        steps.resetStopGate()
        steps.readmit()
        steps.stopWithoutPaste()
        steps.afterStop()
    }
}

/// What the pill offers when the mic or device drops out mid-take.
struct DictationInterruptionPlan: Equatable {
    enum Action: Equatable {
        /// Run the kept audio through the stop pipeline. The focused app may
        /// have changed, so it saves without pasting.
        case transcribeCapturedAudio(autoPaste: Bool)
        case retryDictation
    }

    /// False keeps the kept audio alive for the action to transcribe.
    let cancelRecording: Bool
    let message: String
    let actionTitle: String
    let action: Action

    static func make(hasRecoverableRecording: Bool) -> DictationInterruptionPlan {
        if hasRecoverableRecording {
            return DictationInterruptionPlan(
                cancelRecording: false,
                message: "Recording was interrupted. Transcripted kept the audio captured so far.",
                actionTitle: "Transcribe Captured Audio",
                action: .transcribeCapturedAudio(autoPaste: false)
            )
        }
        return DictationInterruptionPlan(
            cancelRecording: true,
            message: "Recording was interrupted. Check your microphone or audio device, then try again.",
            actionTitle: "Retry Dictation",
            action: .retryDictation
        )
    }
}
