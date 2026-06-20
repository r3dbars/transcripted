import Foundation

enum FeatureDiscoveryTelemetry {
    static let trackedKeyPrefix = "settingsFeatureDiscovered."

    enum FeatureArea: String, CaseIterable {
        case agentSetup = "agent_setup"
        case betaSummaries = "beta_summaries"
        case captureLibrary = "capture_library"
        case localArtifactActions = "local_artifact_actions"
        case permissions
        case speakerReview = "speaker_review"
        case support
        case updateSettings = "update_settings"
    }

    @discardableResult
    static func trackIfNeeded(
        featureArea: FeatureArea,
        pageID: String,
        source: String,
        userDefaults: UserDefaults = .standard
    ) -> Bool {
        guard AnalyticsPreferences.isEnabled(userDefaults: userDefaults) else { return false }

        let key = trackedKeyPrefix + featureArea.rawValue
        guard !userDefaults.bool(forKey: key) else { return false }

        userDefaults.set(true, forKey: key)
        AnalyticsReporter.track(
            "settings_feature_discovered",
            properties: [
                "feature_area": featureArea.rawValue,
                "page_id": pageID,
                "source": source,
            ]
        )
        return true
    }

    @discardableResult
    static func markDiscoveredIfNeeded(
        featureArea: FeatureArea,
        userDefaults: UserDefaults = .standard
    ) -> Bool {
        let key = trackedKeyPrefix + featureArea.rawValue
        guard !userDefaults.bool(forKey: key) else { return false }

        userDefaults.set(true, forKey: key)
        return true
    }
}
