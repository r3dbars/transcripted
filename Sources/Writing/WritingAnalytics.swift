import Foundation

/// Count-only Writing setup analytics routed through `AnalyticsReporter.track`
/// (which sends nothing while anonymous analytics is off). Never sees writing,
/// app names, or bundle IDs. Keeps the `writing_setup_completed` allowlist
/// schema valid.
enum WritingAnalytics {
    enum AppScope: String, Equatable, Sendable {
        case all
        case picked
    }

    struct Setup: Equatable, Sendable {
        let saveEnabled: Bool
        let appScope: AppScope
    }

    static func trackSetupCompleted(_ setup: Setup) {
        AnalyticsReporter.track("writing_setup_completed", properties: setupProperties(setup))
    }

    static func setupProperties(_ setup: Setup) -> [String: String] {
        [
            "save_enabled": setup.saveEnabled ? "true" : "false",
            "autocomplete_enabled": "false",
            "app_scope": setup.appScope.rawValue,
            "model_choice": "none",
        ]
    }
}
