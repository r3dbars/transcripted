import Foundation

struct MeetingPromptTelemetryReadiness: Equatable {
    let microphoneGranted: Bool
    let systemAudioRecordingGranted: Bool
    let meetingRecordingActive: Bool
    let dictationRecordingActive: Bool
}

@available(macOS 14.0, *)
enum MeetingPromptTelemetry {
    enum ChoiceKind: String {
        case record
        case dismiss
        case remindLater = "remind_later"
    }

    enum OutcomeKind: String {
        case dismissed
        case expired
        case remindedLater = "reminded_later"
        case recordingStarted = "recording_started"
        case recordingStartFailed = "recording_start_failed"
        case transcriptSaved = "transcript_saved"
        case transcriptFailed = "transcript_failed"
        case transcriptSkipped = "transcript_skipped"
        case speakerFinalizationFailed = "speaker_finalization_failed"
        case suppressed
    }

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
        // What convinced the detector this was a call (a named tab, the
        // browser also playing audio, just time on the mic...). Coarse enum,
        // never the title itself.
        properties["call_evidence"] = candidate.callEvidence.rawValue
        return properties
    }

    static func funnelProperties(
        for candidate: MeetingPromptDetector.Candidate,
        readiness: MeetingPromptTelemetryReadiness
    ) -> [String: String] {
        [
            "calendar_confidence": candidate.analyticsCalendarConfidence,
            "call_state": candidate.analyticsCallState,
            "prompt_reason": candidate.reason.rawValue,
            "provider": candidate.provider.rawValue,
            "route_ready": routeReady(readiness: readiness) ? "true" : "false",
            "source": candidate.source.analyticsValue,
        ]
    }

    static func choiceProperties(
        for candidate: MeetingPromptDetector.Candidate,
        readiness: MeetingPromptTelemetryReadiness,
        choiceKind: ChoiceKind,
        elapsedSeconds: TimeInterval?
    ) -> [String: String] {
        var properties = funnelProperties(for: candidate, readiness: readiness)
        properties["choice_kind"] = choiceKind.rawValue
        properties["elapsed_bucket"] = elapsedBucket(elapsedSeconds)
        return properties
    }

    static func outcomeProperties(
        for candidate: MeetingPromptDetector.Candidate,
        readiness: MeetingPromptTelemetryReadiness,
        outcomeKind: OutcomeKind,
        elapsedSeconds: TimeInterval? = nil,
        suppressionReason: MeetingPromptSuppressionReason? = nil
    ) -> [String: String] {
        var properties = funnelProperties(for: candidate, readiness: readiness)
        properties["elapsed_bucket"] = elapsedBucket(elapsedSeconds)
        properties["outcome_kind"] = outcomeKind.rawValue
        if let suppressionReason {
            properties["suppression_reason"] = suppressionReason.rawValue
        }
        return properties
    }

    /// A recording's prompt outcome (started, start failed, saved, skipped,
    /// failed). nil when the recording didn't come from a detected prompt
    /// (manual or hotkey), so it never borrows another meeting's prompt.
    static func sessionOutcomeProperties(
        promptProperties: [String: String]?,
        outcomeKind: OutcomeKind,
        elapsedSeconds: TimeInterval? = nil
    ) -> [String: String]? {
        guard let promptProperties else { return nil }
        return outcomeProperties(
            promptProperties: promptProperties,
            outcomeKind: outcomeKind,
            elapsedSeconds: elapsedSeconds
        )
    }

    static func outcomeProperties(
        promptProperties: [String: String],
        outcomeKind: OutcomeKind,
        elapsedSeconds: TimeInterval? = nil
    ) -> [String: String] {
        var properties = promptProperties
        properties["elapsed_bucket"] = elapsedBucket(elapsedSeconds)
        properties["outcome_kind"] = outcomeKind.rawValue
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
            "app_signal": summary.appSignal,
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

    private static func elapsedBucket(_ seconds: TimeInterval?) -> String {
        guard let seconds, seconds >= 0 else {
            return "unknown"
        }
        return AnalyticsReporter.durationBucket(seconds: seconds)
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

// MARK: - Prompt events

/// The analytics events one detected-prompt action fires, built in one place
/// so tests can check each action sends the right set exactly once. The app
/// emits them through `emit`, which defaults to AnalyticsReporter and
/// ActivationTelemetry.
@available(macOS 14.0, *)
extension MeetingPromptTelemetry {
    enum PromptAction {
        /// The capture pill actually appeared.
        case shown(MeetingPromptDetector.Candidate, signals: MeetingPromptSignalSnapshot?)
        /// The user picked Record and the start was accepted.
        case record(MeetingPromptDetector.Candidate, elapsedSeconds: TimeInterval?, signals: MeetingPromptSignalSnapshot?)
        /// The user picked Not now. `backoffKind`, `signals` and
        /// `dismissStreak` are read after the detector applies the dismissal.
        case dismiss(
            MeetingPromptDetector.Candidate,
            elapsedSeconds: TimeInterval?,
            backoffKind: MeetingPromptBackoffKind,
            signals: MeetingPromptSignalSnapshot?,
            dismissStreak: Int
        )
        case remindLater(MeetingPromptDetector.Candidate, elapsedSeconds: TimeInterval?)
        /// The pill timed out with no choice; an outcome, not a user choice.
        case expire(MeetingPromptDetector.Candidate, elapsedSeconds: TimeInterval?)
        /// The detector held a prompt back. One event only: the matching
        /// meeting_prompt_outcome_recorded(outcome_kind=suppressed) doubled
        /// about 33k events a month and carried nothing this one lacks.
        case suppress(MeetingPromptSuppression, signals: MeetingPromptSignalSnapshot?)
    }

    enum PromptEvent: Equatable {
        case analytics(name: String, properties: [String: String])
        /// Only an explicit dismissal counts as abandoning the prompt.
        case promptAbandoned(priorReadyState: String)
    }

    static func events(
        for action: PromptAction,
        readiness: MeetingPromptTelemetryReadiness
    ) -> [PromptEvent] {
        switch action {
        case let .shown(candidate, signals):
            return [
                .analytics(
                    name: "meeting_prompt_shown",
                    properties: properties(for: candidate, readiness: readiness, signals: signals)
                ),
            ]
        case let .record(candidate, elapsedSeconds, signals):
            return [
                .analytics(
                    name: "meeting_prompt_choice_made",
                    properties: choiceProperties(
                        for: candidate,
                        readiness: readiness,
                        choiceKind: .record,
                        elapsedSeconds: elapsedSeconds
                    )
                ),
                .analytics(
                    name: "meeting_prompt_record_selected",
                    properties: properties(for: candidate, readiness: readiness, signals: signals)
                ),
            ]
        case let .dismiss(candidate, elapsedSeconds, backoffKind, signals, dismissStreak):
            return [
                .analytics(
                    name: "meeting_prompt_choice_made",
                    properties: choiceProperties(
                        for: candidate,
                        readiness: readiness,
                        choiceKind: .dismiss,
                        elapsedSeconds: elapsedSeconds
                    )
                ),
                .analytics(
                    name: "meeting_prompt_outcome_recorded",
                    properties: outcomeProperties(
                        for: candidate,
                        readiness: readiness,
                        outcomeKind: .dismissed,
                        elapsedSeconds: elapsedSeconds
                    )
                ),
                .analytics(
                    name: "meeting_prompt_dismissed",
                    properties: properties(
                        for: candidate,
                        readiness: readiness,
                        backoffKind: backoffKind,
                        signals: signals,
                        dismissStreak: dismissStreak
                    )
                ),
                .promptAbandoned(priorReadyState: readyState(readiness: readiness)),
            ]
        case let .remindLater(candidate, elapsedSeconds):
            return [
                .analytics(
                    name: "meeting_prompt_choice_made",
                    properties: choiceProperties(
                        for: candidate,
                        readiness: readiness,
                        choiceKind: .remindLater,
                        elapsedSeconds: elapsedSeconds
                    )
                ),
                .analytics(
                    name: "meeting_prompt_outcome_recorded",
                    properties: outcomeProperties(
                        for: candidate,
                        readiness: readiness,
                        outcomeKind: .remindedLater,
                        elapsedSeconds: elapsedSeconds
                    )
                ),
            ]
        case let .expire(candidate, elapsedSeconds):
            return [
                .analytics(
                    name: "meeting_prompt_outcome_recorded",
                    properties: outcomeProperties(
                        for: candidate,
                        readiness: readiness,
                        outcomeKind: .expired,
                        elapsedSeconds: elapsedSeconds
                    )
                ),
            ]
        case let .suppress(suppression, signals):
            return [
                .analytics(
                    name: "meeting_prompt_suppressed",
                    properties: properties(for: suppression, readiness: readiness, signals: signals)
                ),
            ]
        }
    }

    /// Fires `events(for:readiness:)` in order.
    static func emit(
        _ action: PromptAction,
        readiness: MeetingPromptTelemetryReadiness,
        track: (String, [String: String]) -> Void = { AnalyticsReporter.track($0, properties: $1) },
        trackPromptAbandoned: (String) -> Void = { priorReadyState in
            ActivationTelemetry.trackWorkflowAbandoned(
                workflowKind: .meetingPrompt,
                stage: "prompt_shown",
                reasonKind: .dismissed,
                surface: .meetingOverlay,
                priorReadyState: priorReadyState
            )
        }
    ) {
        for event in events(for: action, readiness: readiness) {
            switch event {
            case let .analytics(name, properties):
                track(name, properties)
            case let .promptAbandoned(priorReadyState):
                trackPromptAbandoned(priorReadyState)
            }
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
