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
        case .general, .models, .shortcuts, .people, .storage, .connectAgent, .privacy, .about:
            return .none
        }
    }
}
