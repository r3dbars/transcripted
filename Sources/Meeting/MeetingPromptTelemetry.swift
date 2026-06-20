import Foundation

struct MeetingPromptTelemetryReadiness: Equatable {
    let microphoneGranted: Bool
    let systemAudioRecordingGranted: Bool
    let meetingRecordingActive: Bool
    let dictationRecordingActive: Bool
}

@available(macOS 14.0, *)
enum MeetingPromptTelemetry {
    static func properties(
        for candidate: MeetingPromptDetector.Candidate,
        readiness: MeetingPromptTelemetryReadiness,
        backoffKind: MeetingPromptBackoffKind? = nil
    ) -> [String: String] {
        var properties = [
            "app_signal": candidate.analyticsAppSignal,
            "calendar_confidence": candidate.analyticsCalendarConfidence,
            "call_state": candidate.analyticsCallState,
            "missing_permission": missingRoutePermission(readiness: readiness),
            "prompt_reason": candidate.reason.rawValue,
            "provider": candidate.provider.rawValue,
            "route_ready": routeReady(readiness: readiness) ? "true" : "false",
            "source": candidate.source.analyticsValue,
        ]
        if let backoffKind {
            properties["backoff_kind"] = backoffKind.rawValue
            properties["cooldown_reason"] = backoffKind.rawValue
        }
        return properties
    }

    static func properties(
        for suppression: MeetingPromptSuppression,
        readiness: MeetingPromptTelemetryReadiness
    ) -> [String: String] {
        var properties = properties(for: suppression.candidate, readiness: readiness)
        properties["suppression_reason"] = suppression.reason.rawValue
        if let cooldownReason = suppression.cooldownReason {
            properties["cooldown_reason"] = cooldownReason
        }
        if let captureActivity = suppression.captureActivity {
            properties["capture_activity"] = captureActivity.rawValue
        }
        return properties
    }

    static func readyState(readiness: MeetingPromptTelemetryReadiness) -> String {
        if readiness.meetingRecordingActive {
            return "recording_active"
        }
        if readiness.dictationRecordingActive {
            return "dictation_active"
        }
        if routeReady(readiness: readiness) {
            return "ready"
        }
        return "not_ready"
    }

    private static func routeReady(readiness: MeetingPromptTelemetryReadiness) -> Bool {
        readiness.microphoneGranted && readiness.systemAudioRecordingGranted
    }

    private static func missingRoutePermission(readiness: MeetingPromptTelemetryReadiness) -> String {
        switch (readiness.microphoneGranted, readiness.systemAudioRecordingGranted) {
        case (true, true):
            return "none"
        case (false, false):
            return "microphone_and_system_audio_recording"
        case (false, true):
            return "microphone"
        case (true, false):
            return "system_audio_recording"
        }
    }
}

@available(macOS 14.0, *)
private extension MeetingPromptSource {
    var analyticsValue: String {
        switch self {
        case .calendarEvent:
            return "calendar_event"
        case .runtimeApp:
            return "runtime_app"
        }
    }
}
