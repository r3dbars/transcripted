import Foundation

private enum PostHogRuntimeConfiguration {
    static let apiKeyInfoKey = "TranscriptedPostHogAPIKey"
    static let hostInfoKey = "TranscriptedPostHogHost"

    static func apiKey() -> String? {
        firstNonEmpty(
            Bundle.main.object(forInfoDictionaryKey: apiKeyInfoKey) as? String,
            ProcessInfo.processInfo.environment["POSTHOG_API_KEY"]
        )
    }

    static func host() -> String {
        firstNonEmpty(
            Bundle.main.object(forInfoDictionaryKey: hostInfoKey) as? String,
            ProcessInfo.processInfo.environment["POSTHOG_HOST"]
        ) ?? "https://us.i.posthog.com"
    }

    static func buildContext() -> String {
        let bundlePath = Bundle.main.bundlePath
        if bundlePath.contains("/build/") || bundlePath.contains("/DerivedData/") {
            return "local_build"
        }
        return "installed_build"
    }

    private static func firstNonEmpty(_ candidates: String?...) -> String? {
        candidates
            .compactMap { $0?.trimmingCharacters(in: .whitespacesAndNewlines) }
            .first(where: { !$0.isEmpty })
    }
}

final class PostHogTracker {
    static let shared = PostHogTracker()

    static var isAvailable: Bool {
        PostHogRuntimeConfiguration.apiKey() != nil
    }

    private init() {}

    private let distinctID: String = {
        let newKey = "transcripted.analytics.distinct_id"
        let legacyKey = "draft.analytics.userID"

        if let existing = UserDefaults.standard.string(forKey: newKey), !existing.isEmpty {
            return existing
        }

        if let legacy = UserDefaults.standard.string(forKey: legacyKey), !legacy.isEmpty {
            UserDefaults.standard.set(legacy, forKey: newKey)
            return legacy
        }

        let created = UUID().uuidString
        UserDefaults.standard.set(created, forKey: newKey)
        return created
    }()

    private let session: URLSession = {
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = 5
        return URLSession(configuration: config)
    }()

    func capture(event entry: ObservabilityEvent) {
        guard let apiKey = PostHogRuntimeConfiguration.apiKey(),
              let url = endpointURL()
        else { return }

        let properties = payloadProperties(for: entry)
        let body: [String: Any] = [
            "api_key": apiKey,
            "event": entry.event,
            "distinct_id": distinctID,
            "properties": properties,
            "timestamp": entry.timestamp,
        ]

        guard let data = try? JSONSerialization.data(withJSONObject: body) else { return }

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = data

        session.dataTask(with: request).resume()
    }

    private func endpointURL() -> URL? {
        guard var components = URLComponents(string: PostHogRuntimeConfiguration.host()) else { return nil }
        components.path = "/i/v0/e/"
        return components.url
    }

    private func payloadProperties(for entry: ObservabilityEvent) -> [String: Any] {
        var properties: [String: Any] = [
            "$process_person_profile": false,
            "engine": entry.engine,
            "level": entry.level,
            "app_version": entry.appVersion,
            "os_version": entry.osVersion,
            "build_context": PostHogRuntimeConfiguration.buildContext(),
        ]

        if let context = entry.context {
            for (key, value) in PostHogPayloadSanitizer.sanitizeProperties(context) {
                properties[key] = value
            }
        }

        return properties
    }
}
