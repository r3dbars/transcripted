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

enum AgentCaptureQueryResult: String, CaseIterable {
    case success
    case emptyNotFound = "empty_not_found"
    case invalidInput = "invalid_input"
    case internalError = "internal_error"
}

struct AgentCaptureQueryBuildIdentity: Equatable {
    static let appVersionEnvironmentKey = "TRANSCRIPTED_MCP_APP_VERSION"
    static let buildChannelEnvironmentKey = "TRANSCRIPTED_ANALYTICS_BUILD_CHANNEL"
    static let buildRevisionEnvironmentKey = "TRANSCRIPTED_ANALYTICS_BUILD_REVISION"
    static let appVersionInfoKey = "CFBundleShortVersionString"
    static let buildChannelInfoKey = "TranscriptedBuildChannel"
    static let buildRevisionInfoKey = "TranscriptedBuildRevision"

    static let unavailable = AgentCaptureQueryBuildIdentity(
        appVersion: nil,
        buildChannel: nil,
        buildRevision: nil
    )

    let appVersion: String?
    let buildChannel: String?
    let buildRevision: String?

    static func resolve(
        environment: [String: String] = ProcessInfo.processInfo.environment,
        bundleInfo: [String: Any]? = Bundle.main.infoDictionary,
        appSupportDirectory: URL? = nil
    ) -> AgentCaptureQueryBuildIdentity {
        let bundleLooksLikeTranscripted = bundleInfo?["CFBundleIdentifier"] as? String
            == AgentCaptureQueryTelemetryConfiguration.appDefaultsSuiteName
            || bundleInfo?[AgentCaptureQueryTelemetryConfiguration.apiKeyInfoKey] != nil
            || bundleInfo?[buildChannelInfoKey] != nil
            || bundleInfo?[buildRevisionInfoKey] != nil
        let bundleAppVersion = bundleLooksLikeTranscripted
            ? bundleInfo?[appVersionInfoKey] as? String
            : nil

        return AgentCaptureQueryBuildIdentity(
            appVersion: firstValid(
                property: "app_version",
                environment[appVersionEnvironmentKey],
                AgentCaptureQueryTelemetryConfiguration.localConfigurationValue(
                    forKey: appVersionInfoKey,
                    appSupportDirectory: appSupportDirectory
                ),
                bundleAppVersion
            ),
            buildChannel: firstValid(
                property: "build_channel",
                environment[buildChannelEnvironmentKey],
                AgentCaptureQueryTelemetryConfiguration.localConfigurationValue(
                    forKey: buildChannelInfoKey,
                    appSupportDirectory: appSupportDirectory
                ),
                bundleInfo?[buildChannelInfoKey] as? String
            ),
            buildRevision: firstValid(
                property: "build_revision",
                environment[buildRevisionEnvironmentKey],
                AgentCaptureQueryTelemetryConfiguration.localConfigurationValue(
                    forKey: buildRevisionInfoKey,
                    appSupportDirectory: appSupportDirectory
                ),
                bundleInfo?[buildRevisionInfoKey] as? String
            )
        )
    }

    static func isSafe(property: String, value: String) -> Bool {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed == value, !trimmed.isEmpty, trimmed.count <= 80 else {
            return false
        }

        switch property {
        case "app_version":
            return trimmed.first?.isNumber == true
                && trimmed.contains(".")
                && trimmed.allSatisfy(isSafeBuildCharacter)
        case "build_channel":
            return ["beta", "debug", "dev", "local", "nightly", "release", "test"].contains(trimmed)
        case "build_revision":
            return (7...40).contains(trimmed.count)
                && trimmed.allSatisfy { $0.isHexDigit }
        default:
            return false
        }
    }

    private static func firstValid(property: String, _ candidates: String?...) -> String? {
        candidates
            .compactMap { $0?.trimmingCharacters(in: .whitespacesAndNewlines) }
            .first { isSafe(property: property, value: $0) }
    }

    private static func isSafeBuildCharacter(_ character: Character) -> Bool {
        character.isLetter
            || character.isNumber
            || character == "."
            || character == "_"
            || character == "-"
    }
}

struct AgentCaptureQueryObservation: Equatable {
    let clientFamily: String
    let toolKind: String
    let captureKind: String
    let result: String
    let sourceCountBucket: String
    let resultCountBucket: String
    let latencyBucket: String
    let buildIdentity: AgentCaptureQueryBuildIdentity

    init(
        toolKind: String,
        captureKind: String,
        result: AgentCaptureQueryResult = .success,
        clientFamily: String = "mcp",
        sourceCount: Int? = nil,
        resultCount: Int? = nil,
        latencyMilliseconds: Int? = nil,
        buildIdentity: AgentCaptureQueryBuildIdentity = .unavailable
    ) {
        self.clientFamily = clientFamily
        self.toolKind = toolKind
        self.captureKind = captureKind
        self.result = result.rawValue
        self.sourceCountBucket = Self.countBucket(sourceCount)
        self.resultCountBucket = Self.countBucket(resultCount)
        self.latencyBucket = Self.latencyBucket(milliseconds: latencyMilliseconds)
        self.buildIdentity = buildIdentity
    }

    var properties: [String: String] {
        var properties = [
            "client_family": clientFamily,
            "capture_kind": captureKind,
            "latency_bucket": latencyBucket,
            "result": result,
            "result_count_bucket": resultCountBucket,
            "source_count_bucket": sourceCountBucket,
            "tool_kind": toolKind,
        ]
        if let appVersion = buildIdentity.appVersion {
            properties["app_version"] = appVersion
        }
        if let buildChannel = buildIdentity.buildChannel {
            properties["build_channel"] = buildChannel
        }
        if let buildRevision = buildIdentity.buildRevision {
            properties["build_revision"] = buildRevision
        }
        return properties
    }

    private static func countBucket(_ count: Int?) -> String {
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

    private static func latencyBucket(milliseconds: Int?) -> String {
        guard let milliseconds else { return "unknown" }
        switch max(0, milliseconds) {
        case ..<100:
            return "lt_100ms"
        case ..<250:
            return "100_249ms"
        case ..<500:
            return "250_499ms"
        case ..<1_000:
            return "500_999ms"
        case ..<2_000:
            return "1_2s"
        case ..<5_000:
            return "2_5s"
        default:
            return "5s_plus"
        }
    }
}

enum AgentCaptureQueryTelemetryPolicy {
    static let eventName = "agent_capture_query_observed"
    // This standalone MCP package cannot import the app target, so this
    // mirrors AnalyticsEventPolicy.agentCaptureQueryProperties. Keep the root
    // AnalyticsEventPolicy parity test green when changing either side.
    static let allowedProperties: Set<String> = [
        "app_version",
        "build_channel",
        "build_revision",
        "client_family",
        "capture_kind",
        "latency_bucket",
        "result",
        "result_count_bucket",
        "source_count_bucket",
        "tool_kind",
    ]
    static let requiredProperties: Set<String> = [
        "client_family",
        "capture_kind",
        "latency_bucket",
        "result",
        "result_count_bucket",
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
        "latency_bucket": ["lt_100ms", "100_249ms", "250_499ms", "500_999ms", "1_2s", "2_5s", "5s_plus", "unknown"],
        "result": Set(AgentCaptureQueryResult.allCases.map(\.rawValue)),
        "result_count_bucket": ["0", "1", "2_3", "4_9", "10_plus", "unknown"],
        "source_count_bucket": ["0", "1", "2_3", "4_9", "10_plus", "unknown"],
        "tool_kind": ["action_items", "commitments", "decisions", "digest", "list", "open_questions", "read", "recap", "recent", "search", "speaker_lookup"],
    ]

    static func sanitize(_ properties: [String: String]) -> [String: String] {
        var sanitized: [String: String] = [:]
        for (key, value) in properties {
            guard allowedProperties.contains(key),
                  !shouldDrop(key: key) else {
                continue
            }
            if let allowed = allowedValues[key] {
                guard allowed.contains(value) else { continue }
            } else {
                guard AgentCaptureQueryBuildIdentity.isSafe(property: key, value: value) else { continue }
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
                localConfigurationValue(forKey: apiKeyInfoKey, appSupportDirectory: appSupportDirectory),
                bundleInfo?[apiKeyInfoKey] as? String
              ),
              let hostString = firstNonEmpty(
                environment["POSTHOG_HOST"],
                localConfigurationValue(forKey: hostInfoKey, appSupportDirectory: appSupportDirectory),
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

    static func localConfigurationValue(forKey key: String, appSupportDirectory: URL?) -> String? {
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

        let properties = observation.properties
        let sanitized = AgentCaptureQueryTelemetryPolicy.sanitize(properties)
        guard Set(sanitized.keys) == Set(properties.keys),
              AgentCaptureQueryTelemetryPolicy.requiredProperties.isSubset(of: Set(sanitized.keys)) else {
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
    @TaskLocal static var invocation: AgentCaptureQueryInvocation?
}

final class AgentCaptureQueryInvocation {
    var toolKind: String
    var captureKind: String
    private(set) var result: AgentCaptureQueryResult = .success
    private(set) var sourceCount: Int?
    private(set) var resultCount: Int?

    init(toolKind: String, captureKind: String) {
        self.toolKind = toolKind
        self.captureKind = captureKind
    }

    func recordSuccess(
        toolKind: String,
        captureKind: String,
        sourceCount: Int?,
        resultCount: Int?
    ) {
        guard result == .success else { return }
        self.toolKind = toolKind
        self.captureKind = captureKind
        self.sourceCount = sourceCount
        self.resultCount = resultCount
    }

    func recordTerminal(
        _ result: AgentCaptureQueryResult,
        sourceCount: Int? = nil,
        resultCount: Int? = nil
    ) {
        self.result = result
        self.sourceCount = sourceCount
        self.resultCount = resultCount
    }
}

func trackAgentCaptureQueryObserved(
    toolKind: String,
    captureKind: String,
    sourceCount: Int?,
    resultCount: Int?
) {
    if let invocation = AgentCaptureQueryTelemetryRuntime.invocation {
        invocation.recordSuccess(
            toolKind: toolKind,
            captureKind: captureKind,
            sourceCount: sourceCount,
            resultCount: resultCount
        )
        return
    }

    AgentCaptureQueryTelemetryRuntime.recorder.track(
        AgentCaptureQueryObservation(
            toolKind: toolKind,
            captureKind: captureKind,
            sourceCount: sourceCount,
            resultCount: resultCount,
            buildIdentity: .resolve()
        )
    )
}

func markAgentCaptureQueryTerminal(
    _ result: AgentCaptureQueryResult,
    sourceCount: Int? = nil,
    resultCount: Int? = nil
) {
    AgentCaptureQueryTelemetryRuntime.invocation?.recordTerminal(
        result,
        sourceCount: sourceCount,
        resultCount: resultCount
    )
}
