import Foundation

enum TranscriptedSettingsPage: String, CaseIterable, Identifiable {
    case home
    case dictations
    case general
    case models
    case shortcuts
    case people
    case storage
    case connectAgent
    case beta
    case privacy
    case support
    case about

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

    var consolidatedDestination: TranscriptedSettingsPage {
        switch self {
        case .models, .shortcuts, .privacy, .beta:
            return .general
        case .support:
            return .about
        default:
            return self
        }
    }

    var title: String {
        switch self {
        case .home: return "Meetings"
        case .dictations: return "Dictations"
        case .general: return "General"
        case .models: return "Models"
        case .shortcuts: return "Shortcuts"
        case .people: return "Speakers"
        case .storage: return "Storage"
        case .connectAgent: return "Agent"
        case .beta: return "Beta"
        case .privacy: return "Privacy"
        case .support: return "Support"
        case .about: return "About"
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
        case .models: return "cpu.fill"
        case .shortcuts: return "keyboard"
        case .people: return "person.2.fill"
        case .storage: return "externaldrive.fill"
        case .connectAgent: return "sparkles"
        case .beta: return "wand.and.stars"
        case .privacy: return "lock.shield.fill"
        case .support: return "questionmark.bubble.fill"
        case .about: return "info.circle.fill"
        }
    }
}
