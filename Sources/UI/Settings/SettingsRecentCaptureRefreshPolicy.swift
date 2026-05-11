import Foundation

enum SettingsRecentCaptureRefreshMode {
    case homeDashboard
    case recentLists
    case none
}

enum SettingsRecentCaptureRefreshPolicy {
    static func mode(for page: TranscriptedSettingsPage) -> SettingsRecentCaptureRefreshMode {
        switch page {
        case .home:
            return .homeDashboard
        case .meetings, .dictations:
            return .recentLists
        case .general, .models, .shortcuts, .people, .storage, .connectAgent, .privacy, .support, .about:
            return .none
        }
    }
}

enum SettingsDashboardRefreshPolicy {
    static let passiveRefreshMinimumInterval: TimeInterval = 1.5

    static func shouldStartRefresh(
        force: Bool,
        isInFlight: Bool,
        lastStartedAt: Date?,
        now: Date,
        minimumInterval: TimeInterval = passiveRefreshMinimumInterval
    ) -> Bool {
        if force {
            return true
        }

        if isInFlight {
            return false
        }

        guard let lastStartedAt else {
            return true
        }

        return now.timeIntervalSince(lastStartedAt) >= minimumInterval
    }
}
