import Foundation

enum TimelineProvider: String, CaseIterable, Identifiable, Equatable, Hashable, Sendable {
    case localFoundation
    case ollama
    case gemini

    static let defaultProvider: TimelineProvider = .localFoundation

    var id: String { rawValue }

    var isCloudProvider: Bool {
        self == .gemini
    }

    var title: String {
        switch self {
        case .localFoundation:
            return "Local"
        case .ollama:
            return "Ollama / LM Studio"
        case .gemini:
            return "Gemini"
        }
    }

    var detail: String {
        switch self {
        case .localFoundation:
            return "Runs on this Mac. Nothing screen-derived leaves the device."
        case .ollama:
            return "Uses your local OpenAI-compatible server."
        case .gemini:
            return "Opt-in cloud provider. Screen-derived context may be sent to Gemini."
        }
    }

    var analyticsValue: String {
        switch self {
        case .localFoundation:
            return "local"
        case .ollama:
            return "ollama"
        case .gemini:
            return "gemini"
        }
    }
}

enum TimelinePreferences {
    static let enabledKey = "timelineEnabled"
    static let onboardingCompletedKey = "timelineOnboardingCompleted"
    static let providerKey = "timelineProvider"
    static let ollamaEndpointKey = "timelineOllamaEndpoint"
    static let storageCapBytesKey = "timelineStorageCapBytes"
    static let blockedBundleIDsKey = "timelineBlockedBundleIDs"
    static let localPromptOverrideKey = "timelineLocalPromptOverride"
    static let ollamaPromptOverrideKey = "timelineOllamaPromptOverride"
    static let geminiPromptOverrideKey = "timelineGeminiPromptOverride"
    static let cloudProviderConsentKey = "timelineCloudProviderConsent"

    static let defaultEnabled = false
    static let defaultOnboardingCompleted = false
    static let defaultOllamaEndpoint = "http://localhost:1234"
    static let defaultStorageCapBytes: Int64 = 5 * 1024 * 1024 * 1024
    static let minimumStorageCapBytes: Int64 = 1 * 1024 * 1024 * 1024
    static let maximumStorageCapBytes: Int64 = 50 * 1024 * 1024 * 1024

    static func isEnabled(userDefaults: UserDefaults = .standard) -> Bool {
        guard userDefaults.object(forKey: enabledKey) != nil else {
            return defaultEnabled
        }
        return userDefaults.bool(forKey: enabledKey)
    }

    static func setEnabled(_ enabled: Bool, userDefaults: UserDefaults = .standard) {
        userDefaults.set(enabled, forKey: enabledKey)
        postChange()
    }

    static func hasCompletedOnboarding(userDefaults: UserDefaults = .standard) -> Bool {
        guard userDefaults.object(forKey: onboardingCompletedKey) != nil else {
            return defaultOnboardingCompleted
        }
        return userDefaults.bool(forKey: onboardingCompletedKey)
    }

    static func setOnboardingCompleted(_ completed: Bool, userDefaults: UserDefaults = .standard) {
        userDefaults.set(completed, forKey: onboardingCompletedKey)
        postChange()
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
        postChange()
    }

    static func ollamaEndpoint(userDefaults: UserDefaults = .standard) -> String {
        let value = userDefaults.string(forKey: ollamaEndpointKey) ?? defaultOllamaEndpoint
        return value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? defaultOllamaEndpoint : value
    }

    static func setOllamaEndpoint(_ endpoint: String, userDefaults: UserDefaults = .standard) {
        userDefaults.set(endpoint.trimmingCharacters(in: .whitespacesAndNewlines), forKey: ollamaEndpointKey)
        postChange()
    }

    static func storageCapBytes(userDefaults: UserDefaults = .standard) -> Int64 {
        guard userDefaults.object(forKey: storageCapBytesKey) != nil else {
            return defaultStorageCapBytes
        }
        return clampedStorageCap(userDefaults.object(forKey: storageCapBytesKey) as? Int64 ?? Int64(userDefaults.integer(forKey: storageCapBytesKey)))
    }

    static func setStorageCapBytes(_ bytes: Int64, userDefaults: UserDefaults = .standard) {
        userDefaults.set(clampedStorageCap(bytes), forKey: storageCapBytesKey)
        postChange()
    }

    static func blockedBundleIDs(userDefaults: UserDefaults = .standard) -> [String] {
        guard let data = userDefaults.data(forKey: blockedBundleIDsKey),
              let decoded = try? JSONDecoder().decode([String].self, from: data) else {
            return []
        }
        return sanitizeBundleIDs(decoded)
    }

    static func setBlockedBundleIDs(_ bundleIDs: [String], userDefaults: UserDefaults = .standard) {
        let sanitized = sanitizeBundleIDs(bundleIDs)
        if let data = try? JSONEncoder().encode(sanitized) {
            userDefaults.set(data, forKey: blockedBundleIDsKey)
        }
        postChange()
    }

    static func promptOverride(for provider: TimelineProvider, userDefaults: UserDefaults = .standard) -> String {
        userDefaults.string(forKey: promptOverrideKey(for: provider)) ?? ""
    }

    static func setPromptOverride(_ value: String, for provider: TimelineProvider, userDefaults: UserDefaults = .standard) {
        userDefaults.set(value, forKey: promptOverrideKey(for: provider))
        postChange()
    }

    static func hasCloudProviderConsent(userDefaults: UserDefaults = .standard) -> Bool {
        userDefaults.bool(forKey: cloudProviderConsentKey)
    }

    static func setCloudProviderConsent(_ consent: Bool, userDefaults: UserDefaults = .standard) {
        userDefaults.set(consent, forKey: cloudProviderConsentKey)
        postChange()
    }

    static func pausedCopy(screenRecordingGranted: Bool) -> String? {
        if !isEnabled() {
            return "Timeline is off. Turn it on when you want Transcripted to capture screen activity."
        }
        if !hasCompletedOnboarding() {
            return "Timeline is waiting for onboarding. Finish setup before capture starts."
        }
        if !screenRecordingGranted {
            return "Timeline is paused until Screen Recording is allowed in System Settings."
        }
        return nil
    }

    static func degradedCopy(for provider: TimelineProvider) -> String? {
        switch provider {
        case .localFoundation:
            return nil
        case .ollama:
            return "Timeline will use your local Ollama or LM Studio endpoint. If it is unavailable, activity cards may pause."
        case .gemini:
            return "Gemini is a cloud provider. Only use it if you are comfortable sending screen-derived context to Gemini."
        }
    }

    static func formattedStorageCap(_ bytes: Int64) -> String {
        ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file)
    }

    private static func promptOverrideKey(for provider: TimelineProvider) -> String {
        switch provider {
        case .localFoundation:
            return localPromptOverrideKey
        case .ollama:
            return ollamaPromptOverrideKey
        case .gemini:
            return geminiPromptOverrideKey
        }
    }

    private static func clampedStorageCap(_ bytes: Int64) -> Int64 {
        min(max(bytes, minimumStorageCapBytes), maximumStorageCapBytes)
    }

    private static func sanitizeBundleIDs(_ bundleIDs: [String]) -> [String] {
        Array(Set(bundleIDs.map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty })).sorted()
    }

    private static func postChange() {
        NotificationCenter.default.post(name: .timelinePreferencesDidChange, object: nil)
    }
}

extension Notification.Name {
    static let timelinePreferencesDidChange = Notification.Name("timelinePreferencesDidChange")
}
