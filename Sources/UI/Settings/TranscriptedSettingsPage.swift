import Foundation

enum TranscriptedSettingsPage: String, CaseIterable, Identifiable {
    case home
    case dictations
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
        case .home: return "Meetings"
        case .dictations: return "Dictations"
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
        case .home: return "1"
        case .dictations: return "2"
        case .people: return "3"
        case .connectAgent: return "4"
        default: return nil
        }
    }

    /// Tooltip text for a sidebar row, including its navigation shortcut when
    /// one exists (e.g. "Speakers  ⌘3").
    var navigationHelp: String {
        guard let key = navigationShortcutKey else { return title }
        return "\(title)  ⌘\(key)"
    }

    var systemImage: String {
        switch self {
        case .home: return "bubble.left.and.bubble.right.fill"
        case .dictations: return "mic.fill"
        case .general: return "gearshape.fill"
        case .people: return "person.2.fill"
        case .connectAgent: return "sparkles"
        }
    }
}
