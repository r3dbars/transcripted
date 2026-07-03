import Foundation

enum TimelineProvider: String, CaseIterable, Equatable, Hashable, Sendable {
    case localFoundation
    case ollama
    case gemini

    static let defaultProvider: TimelineProvider = .localFoundation
}

enum TimelinePreferences {
    static let enabledKey = "timelineEnabled"
    static let providerKey = "timelineProvider"
    static let ollamaEndpointKey = "timelineOllamaEndpoint"
    static let storageCapBytesKey = "timelineStorageCapBytes"
    static let blockedBundleIDsKey = "timelineBlockedBundleIDs"
    static let onboardingCompletedKey = "timelineOnboardingCompleted"

    static let defaultEnabled = false
    static let defaultOllamaEndpoint = "http://localhost:1234"
    static let defaultStorageCapBytes: Int64 = 5 * 1024 * 1024 * 1024

    static func isEnabled(userDefaults: UserDefaults = .standard) -> Bool {
        guard userDefaults.object(forKey: enabledKey) != nil else { return defaultEnabled }
        return userDefaults.bool(forKey: enabledKey)
    }

    static func setEnabled(_ enabled: Bool, userDefaults: UserDefaults = .standard) {
        userDefaults.set(enabled, forKey: enabledKey)
        postChange(for: enabledKey)
    }

    static func provider(userDefaults: UserDefaults = .standard) -> TimelineProvider {
        guard let rawValue = userDefaults.string(forKey: providerKey),
              let provider = TimelineProvider(rawValue: rawValue) else {
            return TimelineProvider.defaultProvider
        }
        return provider
    }

    static func setProvider(_ provider: TimelineProvider, userDefaults: UserDefaults = .standard) {
        userDefaults.set(provider.rawValue, forKey: providerKey)
        postChange(for: providerKey)
    }

    static func ollamaEndpoint(userDefaults: UserDefaults = .standard) -> String {
        guard let value = userDefaults.string(forKey: ollamaEndpointKey),
              !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return defaultOllamaEndpoint
        }
        return value
    }

    static func setOllamaEndpoint(_ endpoint: String, userDefaults: UserDefaults = .standard) {
        userDefaults.set(endpoint, forKey: ollamaEndpointKey)
        postChange(for: ollamaEndpointKey)
    }

    static func storageCapBytes(userDefaults: UserDefaults = .standard) -> Int64 {
        guard userDefaults.object(forKey: storageCapBytesKey) != nil else {
            return defaultStorageCapBytes
        }

        let value = userDefaults.object(forKey: storageCapBytesKey)
        if let int64Value = value as? Int64 {
            return max(0, int64Value)
        }
        if let intValue = value as? Int {
            return Int64(max(0, intValue))
        }
        if let numberValue = value as? NSNumber {
            return max(0, numberValue.int64Value)
        }
        return defaultStorageCapBytes
    }

    static func setStorageCapBytes(_ bytes: Int64, userDefaults: UserDefaults = .standard) {
        userDefaults.set(max(0, bytes), forKey: storageCapBytesKey)
        postChange(for: storageCapBytesKey)
    }

    static func blockedBundleIDs(userDefaults: UserDefaults = .standard) -> [String] {
        guard let data = userDefaults.data(forKey: blockedBundleIDsKey),
              let values = try? JSONDecoder().decode([String].self, from: data) else {
            return []
        }
        return values
    }

    static func setBlockedBundleIDs(_ bundleIDs: [String], userDefaults: UserDefaults = .standard) {
        let cleaned = bundleIDs
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
        if let data = try? JSONEncoder().encode(cleaned) {
            userDefaults.set(data, forKey: blockedBundleIDsKey)
        } else {
            userDefaults.removeObject(forKey: blockedBundleIDsKey)
        }
        postChange(for: blockedBundleIDsKey)
    }

    static func onboardingCompleted(userDefaults: UserDefaults = .standard) -> Bool {
        userDefaults.bool(forKey: onboardingCompletedKey)
    }

    static func setOnboardingCompleted(_ completed: Bool, userDefaults: UserDefaults = .standard) {
        userDefaults.set(completed, forKey: onboardingCompletedKey)
        postChange(for: onboardingCompletedKey)
    }

    private static func postChange(for key: String) {
        NotificationCenter.default.post(name: .timelinePreferencesDidChange, object: key)
    }
}

extension Notification.Name {
    static let timelinePreferencesDidChange = Notification.Name("timelinePreferencesDidChange")
}
