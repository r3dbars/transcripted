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
        hasStartupTask: Bool,
        hasRecordingStartTask: Bool,
        sttIsRecording: Bool
    ) -> StopDecision {
        if !sttIsRecording, (isLoadingOverlay || hasStartupTask || hasRecordingStartTask) {
            return .cancelPendingStart
        }

        if isListeningOverlay || sttIsRecording {
            return .stopRecording
        }

        return .ignoreInactive
    }
}

struct DictationStartAvailabilityPolicy {
    static let meetingWorkMessage = "Finish the current meeting before starting dictation."
    static let speakerReviewMessage = "Finish the speaker review window before starting dictation."

    static func unavailableReason(
        hasMeetingWork: Bool,
        isSpeakerReviewPending: Bool
    ) -> String? {
        if hasMeetingWork {
            return meetingWorkMessage
        }
        if isSpeakerReviewPending {
            return speakerReviewMessage
        }
        return nil
    }
}

struct DictationRecordingStartFailureCleanupPlan: Equatable {
    let outcome: String
    let resetRuntimeSessionToIdle: Bool
    let resetSpeechEngine: Bool
    let hardResetSpeechEngine: Bool
    let reportBeforeCleanup: Bool
    let reportRuntimeStall: Bool
}

struct DictationRecordingStartFailurePolicy {
    static func cleanupPlan(for failureKind: String) -> DictationRecordingStartFailureCleanupPlan {
        let isMicStartTimeout = failureKind == "microphone_start_timeout"
        return DictationRecordingStartFailureCleanupPlan(
            outcome: failureKind,
            resetRuntimeSessionToIdle: true,
            resetSpeechEngine: true,
            hardResetSpeechEngine: isMicStartTimeout,
            reportBeforeCleanup: isMicStartTimeout,
            reportRuntimeStall: false
        )
    }
}

struct DictationMicrophoneTimeoutPresentationPolicy {
    static func message(
        deviceName: String,
        startAttempts: Int,
        inputFormatReady: Bool,
        routeContext: [String: String] = [:]
    ) -> String {
        if isBluetoothFallbackRoute(routeContext) {
            return "Bluetooth audio blocked the mic. Try again."
        }

        if startAttempts > 0, inputFormatReady {
            return "Mic didn't start. Try again or choose another input."
        }

        return "Selected mic unavailable. Choose another input."
    }

    private static func isBluetoothFallbackRoute(_ context: [String: String]) -> Bool {
        let selectedInputClass = context["selected_input_class"] ?? context["input_device_class"]

        return context["selection_overrode_default"] == "true"
            && context["selection_reason"] == "preferredBuiltInForBluetoothHeadset"
            && context["default_input_class"] == "bluetooth"
            && context["default_output_class"] == "bluetooth"
            && selectedInputClass == "built_in"
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
