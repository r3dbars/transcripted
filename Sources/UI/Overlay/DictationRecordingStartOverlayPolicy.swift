import Foundation

struct DictationRecordingStartOverlayPolicy {
    enum Plan: Equatable {
        case skipLoadingAndStartRecording
        case showLoadingWhileWaiting
    }

    static func plan(isRecovering: Bool, inputFormatReady: Bool) -> Plan {
        if !isRecovering, inputFormatReady {
            return .skipLoadingAndStartRecording
        }
        return .showLoadingWhileWaiting
    }
}

struct DictationRecordingStartLifecyclePolicy {
    enum StopDecision: Equatable {
        case cancelPendingStart
        case stopRecording
        case ignoreInactive
    }

    static func stopDecision(
        isLoadingOverlay: Bool,
        isListeningOverlay: Bool,
        hasRecordingStartTask: Bool,
        sttIsRecording: Bool
    ) -> StopDecision {
        if !sttIsRecording, (isLoadingOverlay || hasRecordingStartTask) {
            return .cancelPendingStart
        }

        if isListeningOverlay || sttIsRecording {
            return .stopRecording
        }

        return .ignoreInactive
    }
}

struct DictationRecordingStartFailureCleanupPlan: Equatable {
    let outcome: String
    let resetRuntimeSessionToIdle: Bool
    let resetSpeechEngine: Bool
    let reportRuntimeStall: Bool
}

struct DictationRecordingStartFailurePolicy {
    static func cleanupPlan(for failureKind: String) -> DictationRecordingStartFailureCleanupPlan {
        DictationRecordingStartFailureCleanupPlan(
            outcome: failureKind,
            resetRuntimeSessionToIdle: true,
            resetSpeechEngine: true,
            reportRuntimeStall: false
        )
    }
}

struct DictationActiveTaskCancellationPlan: Equatable {
    let cancelStreamingTask: Bool
    let cancelSpeechEngine: Bool
}

enum DictationActiveTaskCancellationPolicy {
    static func plan(
        cancelRecording: Bool,
        recordingStartWasInFlight: Bool,
        sttIsRecording: Bool,
        sttIsTranscribing: Bool
    ) -> DictationActiveTaskCancellationPlan {
        DictationActiveTaskCancellationPlan(
            cancelStreamingTask: !sttIsTranscribing,
            cancelSpeechEngine: cancelRecording
                && !sttIsTranscribing
                && (sttIsRecording || recordingStartWasInFlight)
        )
    }
}
