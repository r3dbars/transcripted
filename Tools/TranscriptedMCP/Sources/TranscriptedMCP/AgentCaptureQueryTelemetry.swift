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
    let clientFamily: String
    let toolKind: String
    let captureKind: String
    let result: String
    let sourceCountBucket: String

    init(
        toolKind: String,
        captureKind: String,
        result: String = "success",
        clientFamily: String = "mcp",
        sourceCount: Int? = nil
    ) {
        self.clientFamily = clientFamily
        self.toolKind = toolKind
        self.captureKind = captureKind
        self.result = result
        self.sourceCountBucket = Self.sourceCountBucket(sourceCount)
    }

    var properties: [String: String] {
        [
            "client_family": clientFamily,
            "capture_kind": captureKind,
            "result": result,
            "source_count_bucket": sourceCountBucket,
            "tool_kind": toolKind,
        ]
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
        "client_family",
        "capture_kind",
        "result",
        "source_count_bucket",
        "tool_kind",
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
        "client_family": ["mcp"],
        "capture_kind": ["dictation", "meeting", "mixed"],
        "result": ["success"],
        "source_count_bucket": ["0", "1", "2_3", "4_9", "10_plus", "unknown"],
        "tool_kind": ["action_items", "commitments", "decisions", "digest", "list", "open_questions", "read", "recap", "recent", "search", "speaker_lookup"],
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

protocol AgentCaptureQueryTelemetryRecording: AnyObject {
    func track(_ observation: AgentCaptureQueryObservation)
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

extension AgentCaptureQueryTelemetry: AgentCaptureQueryTelemetryRecording {}

enum AgentCaptureQueryTelemetryRuntime {
    static var recorder: AgentCaptureQueryTelemetryRecording = AgentCaptureQueryTelemetry.shared
}

func trackAgentCaptureQueryObserved(
    toolKind: String,
    captureKind: String,
    sourceCount: Int?
) {
    AgentCaptureQueryTelemetryRuntime.recorder.track(
        AgentCaptureQueryObservation(
            toolKind: toolKind,
            captureKind: captureKind,
            sourceCount: sourceCount
        )
    )
}
