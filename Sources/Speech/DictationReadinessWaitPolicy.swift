// DictationReadinessWaitPolicy.swift
// Small policy for deciding how dictation should react while waiting for
// Parakeet input readiness.

enum DictationReadinessWaitAction: Equatable {
    case waitForRecovery
    case refreshInputReadiness
    case forceInputRecovery
    case startRecording
}

struct DictationReadinessWaitPolicy {
    static func action(
        isRecovering: Bool,
        inputFormatReady: Bool,
        readinessRefreshes: Int = 0,
        forcedRecoveryAttempts: Int = 0,
        forcedRecoveryRefreshThreshold: Int = TranscriptedConstants.dictationReadinessForcedRecoveryRefreshes,
        maxForcedRecoveryAttempts: Int = TranscriptedConstants.dictationReadinessForcedRecoveryAttempts
    ) -> DictationReadinessWaitAction {
        if isRecovering {
            return .waitForRecovery
        }

        if inputFormatReady {
            return .startRecording
        }

        if readinessRefreshes >= forcedRecoveryRefreshThreshold,
           forcedRecoveryAttempts < maxForcedRecoveryAttempts {
            return .forceInputRecovery
        }

        return .refreshInputReadiness
    }
}
