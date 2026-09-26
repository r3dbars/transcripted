import Foundation

enum SettingsRecentCaptureRefreshMode {
    case homeDashboard
    case none
}

enum SettingsRecentCaptureRefreshPolicy {
    static func mode(for page: TranscriptedSettingsPage) -> SettingsRecentCaptureRefreshMode {
        switch page {
        case .home, .dictations:
            return .homeDashboard
        case .today, .writing, .general, .people, .connectAgent:
            // Today loads its own snapshot (`TodayViewModel`), and Writing
            // doesn't list meetings or dictations.
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

/// Opening a meeting from Today (or the pill) expands it on Meetings once it
/// is in the loaded list. An older meeting isn't in the first page, so the
/// list pages until it shows up, while that reveal is still wanted.
enum HomeMeetingRevealPagingPolicy {
    static func shouldLoadNextPage(
        pendingKey: String?,
        requestedKey: String,
        canLoadMoreMeetings: Bool
    ) -> Bool {
        pendingKey == requestedKey && canLoadMoreMeetings
    }
}
