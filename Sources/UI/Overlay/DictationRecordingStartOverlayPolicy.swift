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

/// Admission fence for the one stop/checkpoint/transcribe/deliver chain that
/// owns a dictation session. Repeated Stop calls cannot cancel or overwrite
/// the first chain while its durable WAV write is still in flight.
struct DictationStopFinalizationGate {
    private(set) var admittedSessionID: UUID?

    mutating func admit(sessionID: UUID) -> Bool {
        guard admittedSessionID != sessionID else { return false }
        admittedSessionID = sessionID
        return true
    }

    mutating func reset() {
        admittedSessionID = nil
    }
}

struct DictationStartAvailabilityPolicy {
    static let meetingFinishingMessage = "Wait for the meeting recording to finish saving before starting dictation."
    static let speakerReviewMessage = "Speaker review can wait. Dictation is available."

    static func unavailableReason(
        hasActiveMeetingCapture: Bool,
        canShareMeetingMic: Bool,
        isSpeakerReviewPending: Bool
    ) -> String? {
        // Active meeting capture is a supported source: dictation borrows the
        // meeting mic stream instead of opening another audio graph. During
        // finalization that stream is no longer safe to borrow, so wait for
        // teardown instead of starting a competing audio graph.
        if hasActiveMeetingCapture, !canShareMeetingMic {
            return meetingFinishingMessage
        }
        _ = isSpeakerReviewPending
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
            return "Built-in mic unavailable. Choose another input."
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
            // Cancellation is cooperative: queued work can exit immediately,
            // while native inference retains its busy state until it returns.
            cancelStreamingTask: true,
            cancelSpeechEngine: cancelRecording
                && !sttIsTranscribing
                && (sttIsRecording || recordingStartWasInFlight)
        )
    }
}
