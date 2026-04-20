import Foundation

enum TranscriptedSettingsPage: String, CaseIterable, Identifiable {
    case home
    case general
    case shortcuts
    case meetings
    case dictations
    case storage
    case connectAgent
    case privacy
    case about

    var id: String { rawValue }

    var title: String {
        switch self {
        case .home: return "Home"
        case .general: return "General"
        case .shortcuts: return "Shortcuts"
        case .meetings: return "Meetings"
        case .dictations: return "Dictations"
        case .storage: return "Storage"
        case .connectAgent: return "Connect Your Agent"
        case .privacy: return "Privacy"
        case .about: return "About"
        }
    }

    var summary: String {
        switch self {
        case .home:
            return "Quick actions and setup status."
        case .general:
            return "Startup and app-wide behavior."
        case .shortcuts:
            return "Keyboard triggers and Auto Enter app rules."
        case .meetings:
            return "Meeting recording, imports, and speaker controls."
        case .dictations:
            return "Paste-back behavior and dictation feedback."
        case .storage:
            return "Where Transcripted keeps your captures and app data."
        case .connectAgent:
            return "Prompt-first agent setup with MCP and folder fallbacks."
        case .privacy:
            return "Permissions, crash reports, and anonymous analytics."
        case .about:
            return "Version info, updates, and support."
        }
    }

    var systemImage: String {
        switch self {
        case .home: return "house.fill"
        case .general: return "gearshape.fill"
        case .shortcuts: return "keyboard"
        case .meetings: return "person.2.wave.2.fill"
        case .dictations: return "quote.bubble.fill"
        case .storage: return "externaldrive.fill"
        case .connectAgent: return "sparkles"
        case .privacy: return "lock.shield.fill"
        case .about: return "info.circle.fill"
        }
    }
}
