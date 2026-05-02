// DictationReadinessWaitPolicy.swift
// Small policy for deciding how dictation should react while waiting for
// Parakeet input readiness.

enum DictationReadinessWaitAction: Equatable {
    case waitForRecovery
    case refreshInputReadiness
    case forceInputRecovery
    case startRecording
    case startRecoveryRecording
}

struct DictationReadinessWaitPolicy {
    private static let refreshesBeforeRecoveryStart = 4

    static func action(
        isRecovering: Bool,
        inputFormatReady: Bool,
        readinessRefreshes: Int = 0,
        forcedRecoveryAttempts: Int = 0,
        forcedRecoveryRefreshThreshold: Int = TranscriptedConstants.dictationReadinessForcedRecoveryRefreshes,
        maxForcedRecoveryAttempts: Int = TranscriptedConstants.dictationReadinessForcedRecoveryAttempts,
        recoveryStartAttempts: Int = 0
    ) -> DictationReadinessWaitAction {
        if isRecovering {
            return .waitForRecovery
        }

        if inputFormatReady {
            return .startRecording
        }

        if readinessRefreshes >= refreshesBeforeRecoveryStart,
           recoveryStartAttempts == 0 {
            return .startRecoveryRecording
        }

        if readinessRefreshes >= forcedRecoveryRefreshThreshold,
           forcedRecoveryAttempts < maxForcedRecoveryAttempts {
            return .forceInputRecovery
        }

        return .refreshInputReadiness
    }
}
