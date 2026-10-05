import Foundation

enum AudioRetentionWindow: String, CaseIterable, Identifiable {
    case sevenDays = "7_days"
    case thirtyDays = "30_days"
    case never

    var id: String { rawValue }

    var days: Int? {
        switch self {
        case .sevenDays:
            return 7
        case .thirtyDays:
            return 30
        case .never:
            return nil
        }
    }

    var title: String {
        switch self {
        case .sevenDays:
            return "7 days"
        case .thirtyDays:
            return "30 days"
        case .never:
            return "Never"
        }
    }

    var detail: String {
        switch self {
        case .sevenDays:
            return "Retained audio is removed after one week. Markdown transcripts stay."
        case .thirtyDays:
            return "Retained audio is removed after one month. Markdown transcripts stay."
        case .never:
            return "Retained compressed audio stays until you delete it."
        }
    }
}

enum AudioStoragePreferences {
    static let deleteAudioAfterKey = "meeting-audio-delete-after"

    static func deleteAudioAfter(userDefaults: UserDefaults = .standard) -> AudioRetentionWindow {
        guard let rawValue = userDefaults.string(forKey: deleteAudioAfterKey),
              let window = AudioRetentionWindow(rawValue: rawValue) else {
            return .never
        }
        return window
    }

    static func setDeleteAudioAfter(
        _ window: AudioRetentionWindow,
        userDefaults: UserDefaults = .standard
    ) {
        userDefaults.set(window.rawValue, forKey: deleteAudioAfterKey)
        NotificationCenter.default.post(name: .audioStoragePreferencesDidChange, object: nil)
    }
}

extension Notification.Name {
    static let audioStoragePreferencesDidChange = Notification.Name("audioStoragePreferencesDidChange")
}

/// How long a dictation's audio is kept after its transcript saves. Separate
/// from the meeting window: dictation audio defaults to 30 days so a take can
/// be played back or transcribed again, and the text is always kept.
enum DictationAudioKeepWindow: String, CaseIterable, Identifiable {
    case off
    case sevenDays = "7_days"
    case thirtyDays = "30_days"
    case forever

    static let defaultWindow: DictationAudioKeepWindow = .thirtyDays

    var id: String { rawValue }

    /// Days a kept file lives; nil for `forever`, 0 for `off` (keep nothing).
    var days: Int? {
        switch self {
        case .off: return 0
        case .sevenDays: return 7
        case .thirtyDays: return 30
        case .forever: return nil
        }
    }

    var keepsAudio: Bool { self != .off }

    var title: String {
        switch self {
        case .off: return "Don't keep"
        case .sevenDays: return "7 days"
        case .thirtyDays: return "30 days"
        case .forever: return "Forever"
        }
    }

    /// True when switching from `self` to `other` can delete audio that is
    /// already kept, so the change should be confirmed first.
    func deletesKeptAudio(switchingTo other: DictationAudioKeepWindow) -> Bool {
        guard let newDays = other.days else { return false }
        guard let currentDays = days else { return true }
        return newDays < currentDays
    }
}

extension AudioStoragePreferences {
    static let dictationAudioKeepKey = "dictation-audio-keep"

    static func dictationAudioKeepWindow(userDefaults: UserDefaults = .standard) -> DictationAudioKeepWindow {
        guard let rawValue = userDefaults.string(forKey: dictationAudioKeepKey),
              let window = DictationAudioKeepWindow(rawValue: rawValue) else {
            return .defaultWindow
        }
        return window
    }

    static func setDictationAudioKeepWindow(
        _ window: DictationAudioKeepWindow,
        userDefaults: UserDefaults = .standard
    ) {
        userDefaults.set(window.rawValue, forKey: dictationAudioKeepKey)
        NotificationCenter.default.post(name: .audioStoragePreferencesDidChange, object: nil)
    }
}
