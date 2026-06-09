import Foundation

enum LocalMeetingSummaryProvider: String, CaseIterable, Equatable, Hashable, Sendable {
    case gemmaMLX = "gemmaMLX"
    case appleFoundation = "appleFoundation"

    static let defaultProvider: LocalMeetingSummaryProvider = .gemmaMLX

    var title: String {
        switch self {
        case .gemmaMLX:
            return "Gemma local"
        case .appleFoundation:
            return "Apple on-device"
        }
    }

    var detail: String {
        switch self {
        case .gemmaMLX:
            return "Uses the local Gemma 4 MLX runner."
        case .appleFoundation:
            return "Uses Apple Foundation Models on this Mac, including Core Advanced when the system provides it."
        }
    }
}

enum LocalMeetingSummaryPreferences {
    static let enabledKey = "localMeetingSummaryBetaEnabled"
    static let providerKey = "localMeetingSummaryProvider"
    static let defaultEnabled = false

    static func isEnabled(userDefaults: UserDefaults = .standard) -> Bool {
        if userDefaults.object(forKey: enabledKey) == nil {
            return defaultEnabled
        }
        return userDefaults.bool(forKey: enabledKey)
    }

    static func setEnabled(_ enabled: Bool, userDefaults: UserDefaults = .standard) {
        userDefaults.set(enabled, forKey: enabledKey)
    }

    static func provider(userDefaults: UserDefaults = .standard) -> LocalMeetingSummaryProvider {
        guard let rawValue = userDefaults.string(forKey: providerKey),
              let provider = LocalMeetingSummaryProvider(rawValue: rawValue) else {
            return LocalMeetingSummaryProvider.defaultProvider
        }
        return provider
    }

    static func setProvider(_ provider: LocalMeetingSummaryProvider, userDefaults: UserDefaults = .standard) {
        userDefaults.set(provider.rawValue, forKey: providerKey)
    }
}
