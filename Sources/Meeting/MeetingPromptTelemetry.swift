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
        backoffKind: MeetingPromptBackoffKind? = nil,
        signals: MeetingPromptSignalSnapshot? = nil,
        dismissStreak: Int? = nil
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
        // Which sensors were live at the moment of the decision, so accepts and
        // "Not now"s can be sliced by the evidence behind them. Booleans only.
        // Named "output", not "speaker": property keys containing "speaker" are
        // reserved for the sensitive speaker-name taxonomy guard and are
        // dropped by the sanitizer.
        if let signals {
            properties["mic_signal"] = signals.micActive ? "true" : "false"
            properties["output_signal"] = signals.speakerActive ? "true" : "false"
            properties["camera_signal"] = signals.cameraActive ? "true" : "false"
        }
        if let dismissStreak {
            properties["dismiss_streak_bucket"] = MeetingPromptCallTelemetry.dismissStreakBucket(dismissStreak)
        }
        return properties
    }

    static func properties(
        for suppression: MeetingPromptSuppression,
        readiness: MeetingPromptTelemetryReadiness,
        signals: MeetingPromptSignalSnapshot? = nil
    ) -> [String: String] {
        var properties = properties(for: suppression.candidate, readiness: readiness, signals: signals)
        properties["suppression_reason"] = suppression.reason.rawValue
        if let cooldownReason = suppression.cooldownReason {
            properties["cooldown_reason"] = cooldownReason
        }
        if let captureActivity = suppression.captureActivity {
            properties["capture_activity"] = captureActivity.rawValue
        }
        return properties
    }

    static func properties(for summary: MeetingPromptDetectedCallSummary) -> [String: String] {
        [
            "duration_bucket": MeetingPromptCallTelemetry.durationBucket(for: summary.duration),
            "prompt_outcome": summary.promptOutcome.rawValue,
            "provider": summary.provider.rawValue,
            "signal_kinds": summary.signalKinds,
            "was_recorded": summary.wasRecorded ? "true" : "false",
        ]
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
