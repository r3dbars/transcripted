import Foundation

enum AnalyticsRuntimeConfiguration {
    static let apiKeyInfoKey = "TranscriptedPostHogAPIKey"
    static let hostInfoKey = "TranscriptedPostHogHost"
    private static let localOverridesFileName = "observability-overrides.plist"

    static func apiKey() -> String? {
        firstNonEmpty(
            ProcessInfo.processInfo.environment["POSTHOG_API_KEY"],
            localOverrideValue(forKey: apiKeyInfoKey),
            Bundle.main.object(forInfoDictionaryKey: apiKeyInfoKey) as? String
        )
    }

    static func host() -> String? {
        firstNonEmpty(
            ProcessInfo.processInfo.environment["POSTHOG_HOST"],
            localOverrideValue(forKey: hostInfoKey),
            Bundle.main.object(forInfoDictionaryKey: hostInfoKey) as? String
        )
    }

    static func localOverrideValue(forKey key: String) -> String? {
        localOverrideValue(forKey: key, appSupportDirectory: applicationSupportDirectory())
    }

    static func localOverrideValue(forKey key: String, appSupportDirectory: URL) -> String? {
        for url in localOverridesSearchURLs(appSupportDirectory: appSupportDirectory) {
            guard let overrides = NSDictionary(contentsOf: url) as? [String: Any] else {
                continue
            }
            if let value = firstNonEmpty(overrides[key] as? String) {
                return value
            }
        }

        return nil
    }

    static func localOverridesSearchURLs(appSupportDirectory: URL) -> [URL] {
        [
            appSupportDirectory
                .appendingPathComponent("Transcripted", isDirectory: true)
                .appendingPathComponent(localOverridesFileName),
            appSupportDirectory
                .appendingPathComponent("Draft", isDirectory: true)
                .appendingPathComponent(localOverridesFileName),
        ]
    }

    private static func applicationSupportDirectory() -> URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent("Library/Application Support", isDirectory: true)
    }

    private static func firstNonEmpty(_ candidates: String?...) -> String? {
        candidates
            .compactMap { $0?.trimmingCharacters(in: .whitespacesAndNewlines) }
            .first(where: { !$0.isEmpty })
    }
}

final class AnalyticsReporter {
    static let shared = AnalyticsReporter()

    static var isAvailable: Bool {
        shared.apiKey != nil && shared.captureHost != nil
    }

    static func track(_ event: String, properties: [String: String] = [:]) {
        shared.trackEvent(event, properties: properties)
    }

    static func durationBucket(seconds: Double) -> String {
        switch seconds {
        case ..<10:
            return "lt_10s"
        case ..<30:
            return "10_29s"
        case ..<120:
            return "30_119s"
        case ..<600:
            return "2_9m"
        case ..<1800:
            return "10_29m"
        default:
            return "30m_plus"
        }
    }

    static func wordCountBucket(_ count: Int) -> String {
        switch count {
        case ..<10:
            return "lt_10"
        case ..<50:
            return "10_49"
        case ..<150:
            return "50_149"
        case ..<300:
            return "150_299"
        default:
            return "300_plus"
        }
    }

    static func queueDepthBucket(_ depth: Int) -> String {
        switch depth {
        case ..<1:
            return "0"
        case 1:
            return "1"
        case 2...3:
            return "2_3"
        default:
            return "4_plus"
        }
    }

    private init() {}

    // Config is read once from env/plist/overrides file and cached for the app lifetime.
    private let apiKey: String? = AnalyticsRuntimeConfiguration.apiKey()
    private let captureHost: String? = AnalyticsRuntimeConfiguration.host()
    private static let isoDateFormatter = ISO8601DateFormatter()
    private let storageKey = "observability-anonymous-analytics-id"
    private let sessionID = UUID().uuidString
    private let session: URLSession = {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 5
        return URLSession(configuration: configuration)
    }()

    private lazy var distinctID: String = {
        if let existing = UserDefaults.standard.string(forKey: storageKey) {
            return existing
        }

        let newValue = UUID().uuidString
        UserDefaults.standard.set(newValue, forKey: storageKey)
        return newValue
    }()

    private func trackEvent(_ event: String, properties: [String: String]) {
        guard AnalyticsPreferences.isEnabled() else { return }
        guard let apiKey,
              let captureHost,
              let policy = AnalyticsEventPolicy.policy(forEvent: event) else {
            return
        }

        let sanitizedProperties = AnalyticsPayloadSanitizer.sanitizeProperties(
            properties,
            allowedKeys: policy.allowedProperties
        )

        var eventProperties: [String: Any] = sanitizedProperties
        eventProperties["distinct_id"] = distinctID
        eventProperties["app_version"] = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "unknown"
        eventProperties["os_major"] = "\(ProcessInfo.processInfo.operatingSystemVersion.majorVersion)"
        let sanitizedSessionID = AnalyticsPayloadSanitizer.sanitizeText(sessionID)
        if !sanitizedSessionID.isEmpty {
            eventProperties["session_id"] = sanitizedSessionID
        }

        let payload: [String: Any] = [
            "api_key": apiKey,
            "event": policy.name,
            "distinct_id": distinctID,
            "timestamp": Self.isoDateFormatter.string(from: Date()),
            "properties": eventProperties,
        ]

        guard let data = try? JSONSerialization.data(withJSONObject: payload),
              let urlString = normalizedCaptureURL(from: captureHost),
              let url = URL(string: urlString) else {
            return
        }

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = data

        session.dataTask(with: request).resume()
    }

    private func normalizedCaptureURL(from host: String) -> String? {
        let trimmedHost = host.trimmingCharacters(in: .whitespacesAndNewlines)
            .trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        // Security: reject non-HTTPS hosts so analytics payloads (including the api_key and
        // distinct_id) cannot be sent over plaintext HTTP or to an arbitrary URI scheme.
        // A tampered Info.plist or a malicious observability-overrides.plist could otherwise
        // redirect analytics to an attacker-controlled endpoint over plain HTTP.
        guard trimmedHost.lowercased().hasPrefix("https://") else {
            return nil
        }
        return "\(trimmedHost)/capture/"
    }
}
