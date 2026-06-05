import Foundation

enum SettingsRecentCaptureRefreshMode {
    case homeDashboard
    case none
}

enum SettingsRecentCaptureRefreshPolicy {
    static func mode(for page: TranscriptedSettingsPage) -> SettingsRecentCaptureRefreshMode {
        switch page {
        case .home:
            return .homeDashboard
        case .general, .models, .shortcuts, .people, .storage, .connectAgent, .beta, .privacy, .support, .about:
            return .none
        }
    }

    static func shouldStartDashboardRefresh(
        for page: TranscriptedSettingsPage,
        force: Bool,
        isInFlight: Bool,
        lastStartedAt: Date?,
        now: Date,
        minimumInterval: TimeInterval = SettingsDashboardRefreshPolicy.passiveRefreshMinimumInterval
    ) -> Bool {
        guard mode(for: page) == .homeDashboard else {
            return false
        }

        return SettingsDashboardRefreshPolicy.shouldStartRefresh(
            force: force,
            isInFlight: isInFlight,
            lastStartedAt: lastStartedAt,
            now: now,
            minimumInterval: minimumInterval
        )
    }
}

enum SettingsSpeakerQueueRefreshPolicy {
    static func shouldRefreshAfterMeetingTranscriptSave(_ url: URL?) -> Bool {
        url != nil
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
