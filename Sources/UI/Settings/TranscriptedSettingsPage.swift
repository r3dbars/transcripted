import Foundation

enum TranscriptedSettingsPage: String, CaseIterable, Identifiable {
    case home
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
        case .models, .shortcuts, .privacy:
            return .general
        default:
            return self
        }
    }

    var title: String {
        switch self {
        case .home: return "Home"
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

    var summary: String {
        switch self {
        case .home:
            return "Start capture and check setup."
        case .general:
            return "Basic app behavior."
        case .models:
            return "Local transcription model."
        case .shortcuts:
            return "Keys and send-after-paste rules."
        case .people:
            return "Deferred speaker names and duplicates."
        case .storage:
            return "Where your files live."
        case .connectAgent:
            return "One prompt, plus direct paths."
        case .beta:
            return "Experimental local features."
        case .privacy:
            return "Permissions and optional reporting."
        case .support:
            return "Feedback and diagnostics."
        case .about:
            return "Version and updates."
        }
    }

    var systemImage: String {
        switch self {
        case .home: return "house.fill"
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
