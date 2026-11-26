import Foundation

enum TranscriptedSettingsPage: String, CaseIterable, Identifiable {
    /// First page and the default on open. Meetings keeps the `home` raw
    /// value so automation identifiers and analytics `page_id` stay stable.
    case home
    /// Retired: file import lives on Meetings now (its header, a drop
    /// anywhere on the page, ⌘O). Kept so old deep links, the debug channel
    /// and analytics ids still land somewhere; `redirected` sends it to Meetings.
    case files
    case dictations
    case writing
    case people
    case connectAgent
    /// Stats / activity overview. Keeps the `today` raw value so automation
    /// identifiers and analytics `page_id` stay stable.
    case today
    case general

    var id: String { rawValue }

    /// The page a request for this one actually shows. Retired pages
    /// (`.files` and `.writing`) redirect to where their surface lives now.
    var redirected: TranscriptedSettingsPage {
        switch self {
        case .files: return .home
        case .writing: return .connectAgent
        default: return self
        }
    }

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

    var telemetryDestination: ProductUsageTelemetry.Destination {
        switch self {
        case .today: return .today
        case .home: return .meetings
        case .files: return .meetings
        case .dictations: return .dictations
        case .writing: return .writing
        case .general: return .settings
        case .people: return .speakers
        case .connectAgent: return .agent
        }
    }

    var title: String {
        switch self {
        case .home: return "Meetings"
        case .files: return "Transcribe a file"
        case .dictations: return "Dictations"
        case .writing: return "Writing"
        case .people: return "Speakers"
        case .connectAgent: return "Agent"
        case .today: return "Stats"
        case .general: return "Settings"
        }
    }


    /// Conventional ⌘ shortcut for the primary sidebar sections, surfaced in
    /// the "Go" menu and as the sidebar row tooltip. `nil` for the Settings
    /// page (⌘, instead) and retired pages.
    var navigationShortcutKey: String? {
        switch self {
        case .home: return "1"
        case .dictations: return "2"
        case .people: return "3"
        case .connectAgent: return "4"
        case .today: return "5"
        default: return nil
        }
    }

    /// Tooltip text for a sidebar row, including its navigation shortcut when
    /// one exists (e.g. "Speakers  ⌘4").
    var navigationHelp: String {
        guard let key = navigationShortcutKey else { return title }
        return "\(title)  ⌘\(key)"
    }

    var systemImage: String {
        switch self {
        case .home: return "bubble.left.and.bubble.right.fill"
        case .files: return "waveform"
        case .dictations: return "mic.fill"
        case .writing: return "keyboard.fill"
        case .people: return "person.2.fill"
        case .connectAgent: return "sparkles"
        case .today: return "chart.bar.fill"
        case .general: return "gearshape.fill"
        }
    }
}
