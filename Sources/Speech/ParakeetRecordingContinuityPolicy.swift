import Foundation

/// What a user stop does while the engine isn't recording.
enum ParakeetIdleStopAction: Equatable {
    /// Recovery still holds speech from before an interruption: keep it and
    /// cancel the pending restart so the stop transcribes what was captured.
    case drainRecoveredAudio
    /// A zombie reset is waiting to retry with nothing worth keeping: the stop
    /// cancels that restart and releases the idle hardware.
    case cancelPendingZombieRestart
    /// Nothing held: settle an in-flight start or clear the idle timeline.
    case settleIdleGraph
}

/// Whether a dictation keeps its identity and retained audio across a route or
/// zombie-engine restart.
enum ParakeetRecordingContinuityPolicy {
    /// Recovery restarts reuse the ordinary start path. A start that is a
    /// recovery attempt, or that runs while earlier segments are held, continues
    /// the same dictation; only a genuinely new start gets a fresh recording
    /// identity, which revokes the old transcription claim.
    static func startsFreshRecording(
        isRecoveryAttempt: Bool,
        preservingAcrossRecovery: Bool
    ) -> Bool {
        !isRecoveryAttempt && !preservingAcrossRecovery
    }

    /// Real recovered audio wins over a merely pending zombie restart, so a stop
    /// during an in-flight retry drains the speech instead of discarding it.
    static func idleStopAction(
        preservingAcrossRecovery: Bool,
        hasRecoveredAudio: Bool,
        zombieRestartPending: Bool
    ) -> ParakeetIdleStopAction {
        if preservingAcrossRecovery || hasRecoveredAudio {
            return .drainRecoveredAudio
        }
        if zombieRestartPending {
            return .cancelPendingZombieRestart
        }
        return .settleIdleGraph
    }
}
