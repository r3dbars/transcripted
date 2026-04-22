import Foundation

enum TranscriptedSettingsPage: String, CaseIterable, Identifiable {
    case home
    case general
    case models
    case shortcuts
    case meetings
    case dictations
    case people
    case storage
    case connectAgent
    case privacy
    case about

    var id: String { rawValue }

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
        case .home: return "Home"
        case .general: return "General"
        case .models: return "Models"
        case .shortcuts: return "Shortcuts"
        case .meetings: return "Meetings"
        case .dictations: return "Dictation"
        case .people: return "People"
        case .storage: return "Storage"
        case .connectAgent: return "Agent"
        case .privacy: return "Privacy"
        case .about: return "About"
        }
    }

    var summary: String {
        switch self {
        case .home:
            return "Start capture and check setup."
        case .general:
            return "Startup and custom words."
        case .models:
            return "Local transcription model."
        case .shortcuts:
            return "Keys and send-after-paste rules."
        case .meetings:
            return "Recording, imports, and recent calls."
        case .dictations:
            return "Paste-back and sound cues."
        case .people:
            return "Speaker profiles and duplicates."
        case .storage:
            return "Where your files live."
        case .connectAgent:
            return "One prompt, plus direct paths."
        case .privacy:
            return "Permissions and optional reporting."
        case .about:
            return "Version, updates, and support."
        }
    }

    var systemImage: String {
        switch self {
        case .home: return "house.fill"
        case .general: return "gearshape.fill"
        case .models: return "cpu.fill"
        case .shortcuts: return "keyboard"
        case .meetings: return "person.2.wave.2.fill"
        case .dictations: return "quote.bubble.fill"
        case .people: return "person.2.fill"
        case .storage: return "externaldrive.fill"
        case .connectAgent: return "sparkles"
        case .privacy: return "lock.shield.fill"
        case .about: return "info.circle.fill"
        }
    }
}
