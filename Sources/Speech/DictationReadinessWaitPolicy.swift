// DictationReadinessWaitPolicy.swift
// Small policy for deciding how dictation should react while waiting for
// Parakeet input readiness.

enum DictationReadinessWaitAction: Equatable {
    case waitForRecovery
    case refreshInputReadiness
    case startRecording
}

struct DictationReadinessWaitPolicy {
    static func action(isRecovering: Bool, inputFormatReady: Bool) -> DictationReadinessWaitAction {
        if isRecovering {
            return .waitForRecovery
        }

        if inputFormatReady {
            return .startRecording
        }

        return .refreshInputReadiness
    }
}
