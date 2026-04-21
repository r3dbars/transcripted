import Foundation

enum MenuBarOptionalItem: String, CaseIterable, Hashable, Identifiable {
    case recentMeetings
    case connectAgent
    case submitFeedback
    case updates

    var id: String { rawValue }

    var title: String {
        switch self {
        case .recentMeetings:
            return "Recent Meetings"
        case .connectAgent:
            return "Connect Agent"
        case .submitFeedback:
            return "Submit Feedback"
        case .updates:
            return "Updates"
        }
    }

    var detail: String {
        switch self {
        case .recentMeetings:
            return "Open saved meeting notes."
        case .connectAgent:
            return "Open agent setup."
        case .submitFeedback:
            return "Send feedback from the menu."
        case .updates:
            return "Show update checks in the menu."
        }
    }

    var symbolName: String {
        switch self {
        case .recentMeetings:
            return "clock.arrow.circlepath"
        case .connectAgent:
            return "sparkles"
        case .submitFeedback:
            return "bubble.left"
        case .updates:
            return "arrow.triangle.2.circlepath.circle"
        }
    }

    fileprivate var preferenceKey: String {
        "menu-bar-show-\(rawValue)"
    }
}

enum MenuBarVisibilityPreferences {
    static func isVisible(
        _ item: MenuBarOptionalItem,
        userDefaults: UserDefaults = .standard
    ) -> Bool {
        guard userDefaults.object(forKey: item.preferenceKey) != nil else { return true }
        return userDefaults.bool(forKey: item.preferenceKey)
    }

    static func setVisible(
        _ item: MenuBarOptionalItem,
        _ visible: Bool,
        userDefaults: UserDefaults = .standard
    ) {
        userDefaults.set(visible, forKey: item.preferenceKey)
        NotificationCenter.default.post(name: .menuBarVisibilityPreferencesDidChange, object: item)
    }

    static func snapshot(userDefaults: UserDefaults = .standard) -> [MenuBarOptionalItem: Bool] {
        Dictionary(uniqueKeysWithValues: MenuBarOptionalItem.allCases.map {
            ($0, isVisible($0, userDefaults: userDefaults))
        })
    }
}

extension Notification.Name {
    static let menuBarVisibilityPreferencesDidChange = Notification.Name("menuBarVisibilityPreferencesDidChange")
}
