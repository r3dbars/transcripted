import Foundation

enum DictationPasteRetryTelemetry {
    static let eventName = "dictation_paste_retry_completed"

    @discardableResult
    static func performUserRetry(
        track: (String, [String: String]) -> Void = { event, properties in
            AnalyticsReporter.track(event, properties: properties)
        },
        retry: () -> TextPasteOutcome
    ) -> TextPasteOutcome {
        let outcome = retry()
        track(eventName, properties(for: outcome))
        return outcome
    }

    private static func properties(for outcome: TextPasteOutcome) -> [String: String] {
        switch outcome {
        case .pasted:
            return ["result": "pasted"]
        case .copied(_, reason: let reason):
            return [
                "reason": reason.analyticsName,
                "result": "copied",
            ]
        case .failed:
            return [
                "reason": "clipboard_unavailable",
                "result": "failed",
            ]
        }
    }
}

private extension TextPasteCopyReason {
    var analyticsName: String {
        switch self {
        case .accessibilityMissing:
            return "accessibility_missing"
        case .pasteEventCreationFailed:
            return "paste_event_creation_failed"
        case .focusChanged:
            return "focus_changed"
        case .pasteNotConfirmed:
            return "paste_not_confirmed"
        case .pasteConfirmationUnavailable, .pasteConfirmationUnavailableAutoSendEligible:
            return "confirmation_unavailable"
        }
    }
}
