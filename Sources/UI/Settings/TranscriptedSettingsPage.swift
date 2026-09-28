import Foundation

enum TranscriptedSettingsPage: String, CaseIterable, Identifiable {
    /// First page and the default on open. Meetings keeps the `home` raw
    /// value so automation identifiers and analytics `page_id` stay stable.
    case today
    case home
    case dictations
    case writing
    case general
    case people
    case connectAgent

    var id: String { rawValue }

    var automationIdentifier: String {
        switch self {
        case .connectAgent:
            return "transcripted.settings.sidebar.connect-agent"
        default:
            return "transcripted.settings.sidebar.\(rawValue)"
        }
    }

    var analyticsValue: String {
        switch self {
        case .connectAgent:
            return "connect_agent"
        default:
            return rawValue
        }
    }

    var title: String {
        switch self {
        case .today: return "Today"
        case .home: return "Meetings"
        case .dictations: return "Dictations"
        case .writing: return "Writing"
        case .general: return "Settings"
        case .people: return "Speakers"
        case .connectAgent: return "Agent"
        }
    }


    /// Conventional ⌘ shortcut for the primary sidebar sections, surfaced in
    /// the "Go" menu and as the sidebar row tooltip. `nil` for gear-gated
    /// settings pages, which have no navigation shortcut.
    var navigationShortcutKey: String? {
        switch self {
        case .today: return "1"
        case .home: return "2"
        case .dictations: return "3"
        case .writing: return "4"
        case .people: return "5"
        case .connectAgent: return "6"
        default: return nil
        }
    }

    /// Tooltip text for a sidebar row, including its navigation shortcut when
    /// one exists (e.g. "Speakers  ⌘5").
    var navigationHelp: String {
        guard let key = navigationShortcutKey else { return title }
        return "\(title)  ⌘\(key)"
    }

    var systemImage: String {
        switch self {
        case .today: return "sun.max.fill"
        case .home: return "bubble.left.and.bubble.right.fill"
        case .dictations: return "mic.fill"
        case .writing: return "keyboard.fill"
        case .general: return "gearshape.fill"
        case .people: return "person.2.fill"
        case .connectAgent: return "sparkles"
        }
    }
}

/// The Writing row's quiet "New" badge in the sidebar. It shows until
/// `dismissedDefaultsKey` is true in `UserDefaults.standard`; the Writing page
/// sets it when the user finishes setup.
enum WritingSidebarNewBadge {
    static let dismissedDefaultsKey = "WritingSidebarNewBadgeDismissed"

    static func isShown(for page: TranscriptedSettingsPage, dismissed: Bool) -> Bool {
        page == .writing && !dismissed
    }
}
