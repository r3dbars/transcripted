import Foundation

enum UXConfusionTelemetry {
    enum Surface: String {
        case onboarding
        case home
        case homeRow = "home_row"
        case settings
        case support
    }

    enum SignalKind: String {
        case onboardingExited = "onboarding_exited"
        case setupAbandoned = "setup_abandoned"
        case repeatedSettingsVisit = "repeated_settings_visit"
        case disabledActionAttempted = "disabled_action_attempted"
        case emptyStateExited = "empty_state_exited"
        case failedMeetingDetailsOpened = "failed_meeting_details_opened"
    }

    enum RecoveryKind: String {
        case retryFromFailure = "retry_from_failure"
        case supportDiagnostics = "support_diagnostics"
    }

    enum Result: String {
        case blocked
        case copied
        case failed
        case queued
        case started
    }

    static func trackSignal(
        _ signalKind: SignalKind,
        surface: Surface,
        pageID: String? = nil,
        stepID: String? = nil,
        stepIndex: Int? = nil,
        actionID: String? = nil,
        failureKind: String? = nil,
        reasonKind: String? = nil,
        visitCountBucket: String? = nil,
        elapsedBucket: String? = nil,
        retryability: String? = nil
    ) {
        AnalyticsReporter.track(
            "ux_confusion_signal_observed",
            properties: properties(
                base: [
                    "signal_kind": signalKind.rawValue,
                    "surface": surface.rawValue,
                ],
                pageID: pageID,
                stepID: stepID,
                stepIndex: stepIndex,
                actionID: actionID,
                failureKind: failureKind,
                reasonKind: reasonKind,
                visitCountBucket: visitCountBucket,
                elapsedBucket: elapsedBucket,
                retryability: retryability
            )
        )
    }

    static func trackRecovery(
        _ recoveryKind: RecoveryKind,
        surface: Surface,
        pageID: String? = nil,
        actionID: String? = nil,
        failureKind: String? = nil,
        reasonKind: String? = nil,
        result: Result,
        retryability: String? = nil
    ) {
        AnalyticsReporter.track(
            "ux_recovery_action_taken",
            properties: properties(
                base: [
                    "recovery_kind": recoveryKind.rawValue,
                    "result": result.rawValue,
                    "surface": surface.rawValue,
                ],
                pageID: pageID,
                actionID: actionID,
                failureKind: failureKind,
                reasonKind: reasonKind,
                retryability: retryability
            )
        )
    }

    static func visitCountBucket(_ count: Int) -> String? {
        switch count {
        case ..<3:
            return nil
        case 3...4:
            return "3_4"
        case 5...9:
            return "5_9"
        default:
            return "10_plus"
        }
    }

    private static func properties(
        base: [String: String],
        pageID: String? = nil,
        stepID: String? = nil,
        stepIndex: Int? = nil,
        actionID: String? = nil,
        failureKind: String? = nil,
        reasonKind: String? = nil,
        visitCountBucket: String? = nil,
        elapsedBucket: String? = nil,
        retryability: String? = nil
    ) -> [String: String] {
        var properties = base
        properties["page_id"] = pageID
        properties["step_id"] = stepID
        properties["step_index"] = stepIndex.map(String.init)
        properties["action_id"] = actionID
        properties["failure_kind"] = failureKind
        properties["reason_kind"] = reasonKind
        properties["visit_count_bucket"] = visitCountBucket
        properties["elapsed_bucket"] = elapsedBucket
        properties["retryability"] = retryability
        return properties
    }
}
