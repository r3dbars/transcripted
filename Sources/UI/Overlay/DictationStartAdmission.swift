import Foundation

/// The first step of starting a dictation: decide whether this press becomes
/// a new take, and count it the way the start-rate metrics need.
///
/// `DictationSessionController.startDictation` runs this with the real router,
/// overlay and telemetry; tests run it with fakes, so the counting rules are
/// checked through behavior instead of by reading the controller's source:
///
/// - A press while already dictating is ignored and not counted.
/// - A press while the last take is still finishing is queued and not counted
///   yet. It's counted when it starts, or when the queue drops it.
/// - Every other press is counted (`dictation_start_requested`) before any
///   guard can refuse it, because a refused start is still a start the user
///   asked for. It's counted before the session id exists, so it never
///   borrows the previous session's id.
/// - Each guard that refuses reports its own reason.
@MainActor
enum DictationStartAdmission {
    enum Refusal: String, Equatable, CaseIterable {
        /// A failed checkpoint may leave native audio as the only copy;
        /// a fresh capture would clear it.
        case unsavedCaptureRecoveryPending = "unsaved_capture_recovery_pending"
        case previousDictationTranscribing = "previous_dictation_transcribing"
        case dictationUnavailable = "dictation_unavailable"
    }

    enum Decision: Equatable {
        case alreadyDictating
        case queuedBehindFinishingTake
        case refused(Refusal, message: String?)
        case admitted
    }

    struct Steps {
        var isDictating: @MainActor () -> Bool
        /// Remembers the press if the last take is still finishing; true when it did.
        var rememberPressIfFinishing: @MainActor () -> Bool
        /// Puts the Notch island up on the key press, before the telemetry and
        /// checks below, so it lands on the next frame.
        var showStartingIsland: @MainActor () -> Void
        var countRequest: @MainActor () -> Void
        var blocksNewCapture: @MainActor () -> Bool
        var previousTakeIsTranscribing: @MainActor () -> Bool
        var unavailableReason: @MainActor () -> String?
        var countRefusal: @MainActor (Refusal) -> Void
    }

    static func decide(_ steps: Steps) -> Decision {
        guard !steps.isDictating() else { return .alreadyDictating }
        if steps.rememberPressIfFinishing() { return .queuedBehindFinishingTake }
        steps.showStartingIsland()
        steps.countRequest()
        if steps.blocksNewCapture() {
            steps.countRefusal(.unsavedCaptureRecoveryPending)
            return .refused(.unsavedCaptureRecoveryPending, message: nil)
        }
        if steps.previousTakeIsTranscribing() {
            steps.countRefusal(.previousDictationTranscribing)
            return .refused(.previousDictationTranscribing, message: nil)
        }
        if let reason = steps.unavailableReason() {
            steps.countRefusal(.dictationUnavailable)
            return .refused(.dictationUnavailable, message: reason)
        }
        return .admitted
    }
}
