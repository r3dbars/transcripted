import Foundation

enum MenuBarOptionalItem: String, CaseIterable, Hashable, Identifiable {
    case startDictation
    case startMeeting
    case pasteLastDictation
    case recentMeetings

    var id: String { rawValue }

    var title: String {
        switch self {
        case .startDictation:
            return "Start Dictation"
        case .startMeeting:
            return "Start Meeting"
        case .pasteLastDictation:
            return "Paste Last Dictation"
        case .recentMeetings:
            return "Recent Meetings"
        }
    }

    var detail: String {
        switch self {
        case .startDictation:
            return "Show the dictation starter."
        case .startMeeting:
            return "Show the meeting recorder."
        case .pasteLastDictation:
            return "Show the latest dictation paste action."
        case .recentMeetings:
            return "Open saved meeting notes."
        }
    }

    var symbolName: String {
        switch self {
        case .startDictation:
            return "mic.fill"
        case .startMeeting:
            return "record.circle.fill"
        case .pasteLastDictation:
            return "arrow.turn.down.right"
        case .recentMeetings:
            return "clock.arrow.circlepath"
        }
    }

    fileprivate var preferenceKey: String {
        "menu-bar-primary-show-\(rawValue)"
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
