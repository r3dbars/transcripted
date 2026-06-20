import Foundation

private struct PostHogCaptureRequest: Encodable {
    let apiKey: String
    let event: String
    let distinctID: String
    let timestamp: String
    let properties: [String: String]

    enum CodingKeys: String, CodingKey {
        case apiKey = "api_key"
        case event
        case distinctID = "distinct_id"
        case timestamp
        case properties
    }
}

struct AgentCaptureQueryObservation: Equatable {
    let agentTarget: String
    let queryKind: String
    let artifactKind: String
    let result: String
    let surface: String
    let returnWindowBucket: String
    let captureAgeBucket: String
    let sourceCountBucket: String

    init(
        queryKind: String,
        artifactKind: String,
        result: String = "success",
        surface: String = "mcp",
        agentTarget: String = "mcp_client",
        captureDate: Date? = nil,
        sourceCount: Int? = nil,
        now: Date = Date()
    ) {
        self.agentTarget = agentTarget
        self.queryKind = queryKind
        self.artifactKind = artifactKind
        self.result = result
        self.surface = surface
        self.returnWindowBucket = Self.returnWindowBucket(since: captureDate, now: now)
        self.captureAgeBucket = Self.captureAgeBucket(since: captureDate, now: now)
        self.sourceCountBucket = Self.sourceCountBucket(sourceCount)
    }

    var properties: [String: String] {
        [
            "agent_target": agentTarget,
            "artifact_kind": artifactKind,
            "capture_age_bucket": captureAgeBucket,
            "query_kind": queryKind,
            "result": result,
            "return_window_bucket": returnWindowBucket,
            "source_count_bucket": sourceCountBucket,
            "surface": surface,
        ]
    }

    private static func captureAgeBucket(since date: Date?, now: Date) -> String {
        guard let date else { return "unknown" }
        let hours = max(0, now.timeIntervalSince(date)) / 3_600
        switch hours {
        case ..<12:
            return "lt_12h"
        case ..<24:
            return "12_24h"
        case ..<48:
            return "24_48h"
        case ..<168:
            return "2_7d"
        default:
            return "older"
        }
    }

    private static func returnWindowBucket(since date: Date?, now: Date) -> String {
        guard let date else { return "unknown" }
        let hours = max(0, now.timeIntervalSince(date)) / 3_600
        switch hours {
        case ..<18:
            return "same_day"
        case ..<36:
            return "18_36h"
        case ..<72:
            return "36_72h"
        case ..<168:
            return "3_7d"
        default:
            return "older"
        }
    }

    private static func sourceCountBucket(_ count: Int?) -> String {
        guard let count else { return "unknown" }
        switch count {
        case ..<1:
            return "0"
        case 1:
            return "1"
        case 2...3:
            return "2_3"
        case 4...9:
            return "4_9"
        default:
            return "10_plus"
        }
    }
}

enum AgentCaptureQueryTelemetryPolicy {
    static let eventName = "agent_capture_query_observed"
    // This standalone MCP package cannot import the app target, so this
    // mirrors AnalyticsEventPolicy.agentCaptureQueryProperties. Keep the root
    // AnalyticsEventPolicy parity test green when changing either side.
    static let allowedProperties: Set<String> = [
        "agent_target",
        "artifact_kind",
        "capture_age_bucket",
        "query_kind",
        "result",
        "return_window_bucket",
        "source_count_bucket",
        "surface",
    ]
    private static let sensitiveKeyFragments = [
        "audio",
        "authorization",
        "bundle",
        "credential",
        "email",
        "error",
        "file",
        "name",
        "password",
        "path",
        "speaker",
        "source_app",
        "secret",
        "text",
        "title",
        "token",
        "transcript",
        "url",
    ]
    private static let allowedValues: [String: Set<String>] = [
        "agent_target": ["mcp_client"],
        "artifact_kind": ["dictation", "meeting", "mixed"],
        "capture_age_bucket": ["lt_12h", "12_24h", "24_48h", "2_7d", "older", "unknown"],
        "query_kind": ["list", "read", "recap", "recent", "search", "speaker_lookup"],
        "result": ["success"],
        "return_window_bucket": ["same_day", "18_36h", "36_72h", "3_7d", "older", "unknown"],
        "source_count_bucket": ["0", "1", "2_3", "4_9", "10_plus", "unknown"],
        "surface": ["mcp"],
    ]

    static func sanitize(_ properties: [String: String]) -> [String: String] {
        var sanitized: [String: String] = [:]
        for (key, value) in properties {
            guard allowedProperties.contains(key),
                  !shouldDrop(key: key),
                  allowedValues[key]?.contains(value) == true else {
                continue
            }
            sanitized[key] = value
        }
        return sanitized
    }

    private static func shouldDrop(key: String) -> Bool {
        let normalized = key.lowercased()
        return sensitiveKeyFragments.contains { normalized.contains($0) }
    }
}

struct AgentCaptureQueryTelemetryConfiguration {
    let apiKey: String
    let host: URL
    let distinctID: String

    static let apiKeyInfoKey = "TranscriptedPostHogAPIKey"
    static let hostInfoKey = "TranscriptedPostHogHost"
    static let appDefaultsSuiteName = "com.justinbetker.draft"
    static let mcpObservabilityFileName = "mcp-observability.plist"
    private static let localOverridesFileName = "observability-overrides.plist"
    private static let analyticsEnabledKey = "observability-anonymous-analytics-enabled"
    private static let distinctIDKey = "observability-anonymous-analytics-id"

    static func resolve(
        environment: [String: String] = ProcessInfo.processInfo.environment,
        userDefaults: UserDefaults = .standard,
        appUserDefaults: UserDefaults? = UserDefaults(suiteName: appDefaultsSuiteName),
        appSupportDirectory: URL? = nil,
        bundleInfo: [String: Any]? = Bundle.main.infoDictionary
    ) -> AgentCaptureQueryTelemetryConfiguration? {
        guard analyticsEnabled(userDefaults: userDefaults, appUserDefaults: appUserDefaults),
              let apiKey = firstNonEmpty(
                environment["POSTHOG_API_KEY"],
                localOverrideValue(forKey: apiKeyInfoKey, appSupportDirectory: appSupportDirectory),
                bundleInfo?[apiKeyInfoKey] as? String
              ),
              let hostString = firstNonEmpty(
                environment["POSTHOG_HOST"],
                localOverrideValue(forKey: hostInfoKey, appSupportDirectory: appSupportDirectory),
                bundleInfo?[hostInfoKey] as? String
              ),
              let host = URL(string: hostString),
              ["https"].contains(host.scheme?.lowercased() ?? "") else {
            return nil
        }

        let distinctID = resolveDistinctID(userDefaults: userDefaults, appUserDefaults: appUserDefaults)

        return AgentCaptureQueryTelemetryConfiguration(apiKey: apiKey, host: host, distinctID: distinctID)
    }

    private static func analyticsEnabled(userDefaults: UserDefaults, appUserDefaults: UserDefaults?) -> Bool {
        if let appUserDefaults,
           appUserDefaults.object(forKey: analyticsEnabledKey) != nil {
            return appUserDefaults.bool(forKey: analyticsEnabledKey)
        }
        guard userDefaults.object(forKey: analyticsEnabledKey) != nil else { return true }
        return userDefaults.bool(forKey: analyticsEnabledKey)
    }

    private static func resolveDistinctID(userDefaults: UserDefaults, appUserDefaults: UserDefaults?) -> String {
        if let existing = appUserDefaults?.string(forKey: distinctIDKey), !existing.isEmpty {
            return existing
        }
        if let existing = userDefaults.string(forKey: distinctIDKey), !existing.isEmpty {
            return existing
        }

        let newValue = UUID().uuidString
        (appUserDefaults ?? userDefaults).set(newValue, forKey: distinctIDKey)
        return newValue
    }

    private static func localOverrideValue(forKey key: String, appSupportDirectory: URL?) -> String? {
        let appSupport = appSupportDirectory ?? FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
        guard let appSupport else { return nil }

        for url in [
            appSupport
                .appendingPathComponent("Transcripted", isDirectory: true)
                .appendingPathComponent(localOverridesFileName),
            appSupport
                .appendingPathComponent("Draft", isDirectory: true)
                .appendingPathComponent(localOverridesFileName),
            appSupport
                .appendingPathComponent("Transcripted", isDirectory: true)
                .appendingPathComponent(mcpObservabilityFileName),
        ] {
            guard let data = try? Data(contentsOf: url),
                  let plist = try? PropertyListSerialization.propertyList(from: data, options: [], format: nil),
                  let overrides = plist as? [String: String],
                  let value = firstNonEmpty(overrides[key]) else {
                continue
            }
            return value
        }

        return nil
    }

    private static func firstNonEmpty(_ candidates: String?...) -> String? {
        candidates
            .compactMap { $0?.trimmingCharacters(in: .whitespacesAndNewlines) }
            .first(where: { !$0.isEmpty })
    }
}

final class AgentCaptureQueryTelemetry {
    static let shared = AgentCaptureQueryTelemetry()
    private static let isoDateFormatter = ISO8601DateFormatter()
    private let session: URLSession
    private let configurationProvider: () -> AgentCaptureQueryTelemetryConfiguration?

    init(
        configuration: AgentCaptureQueryTelemetryConfiguration? = nil,
        configurationProvider: (() -> AgentCaptureQueryTelemetryConfiguration?)? = nil,
        session: URLSession = {
            let config = URLSessionConfiguration.ephemeral
            config.timeoutIntervalForRequest = 5
            return URLSession(configuration: config)
        }()
    ) {
        if let configurationProvider {
            self.configurationProvider = configurationProvider
        } else if let configuration {
            self.configurationProvider = { configuration }
        } else {
            self.configurationProvider = { AgentCaptureQueryTelemetryConfiguration.resolve() }
        }
        self.session = session
    }

    func track(_ observation: AgentCaptureQueryObservation) {
        guard let request = makeRequest(for: observation) else { return }
        session.dataTask(with: request).resume()
    }

    func makeRequest(for observation: AgentCaptureQueryObservation, now: Date = Date()) -> URLRequest? {
        guard let configuration = configurationProvider() else { return nil }

        let sanitized = AgentCaptureQueryTelemetryPolicy.sanitize(observation.properties)
        guard sanitized.count == AgentCaptureQueryTelemetryPolicy.allowedProperties.count else {
            return nil
        }

        let payload = PostHogCaptureRequest(
            apiKey: configuration.apiKey,
            event: AgentCaptureQueryTelemetryPolicy.eventName,
            distinctID: configuration.distinctID,
            timestamp: Self.isoDateFormatter.string(from: now),
            properties: sanitized.merging(["distinct_id": configuration.distinctID]) { current, _ in current }
        )

        guard let data = try? JSONEncoder().encode(payload) else { return nil }

        var request = URLRequest(url: configuration.host.appendingPathComponent("capture/"))
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = data
        return request
    }
}

func trackAgentCaptureQueryObserved(
    queryKind: String,
    artifactKind: String,
    captureDate: Date?,
    sourceCount: Int?
) {
    AgentCaptureQueryTelemetry.shared.track(
        AgentCaptureQueryObservation(
            queryKind: queryKind,
            artifactKind: artifactKind,
            captureDate: captureDate,
            sourceCount: sourceCount
        )
    )
}

func parseCaptureDate(_ raw: String?) -> Date? {
    guard let raw, !raw.isEmpty else { return nil }

    for options in [
        ISO8601DateFormatter.Options.withInternetDateTime,
        [.withInternetDateTime, .withFractionalSeconds],
    ] {
        let iso = ISO8601DateFormatter()
        iso.formatOptions = options
        if let date = iso.date(from: raw) {
            return date
        }
    }

    let formats = [
        "yyyy-MM-dd'T'HH:mm:ssZ",
        "yyyy-MM-dd'T'HH:mm:ssZZZZZ",
        "yyyy-MM-dd'T'HH:mm:ss",
        "yyyy-MM-dd HH:mm:ss",
        "yyyy-MM-dd",
    ]
    for format in formats {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = format
        if let date = formatter.date(from: raw) {
            return date
        }
    }

    return nil
}
