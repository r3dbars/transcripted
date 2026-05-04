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
