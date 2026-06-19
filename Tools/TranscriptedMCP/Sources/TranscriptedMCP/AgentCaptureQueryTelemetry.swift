import Foundation
import MCP

private struct MCPAnalyticsCaptureRequest: Encodable {
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
}

enum AgentCaptureQueryTelemetry {
    static let eventName = "agent_capture_query_observed"

    private static let allowedClientFamilies = Set(["claude_desktop", "claude_code", "codex", "cursor", "unknown"])
    private static let allowedProperties = Set(["capture_kind", "client_family", "result", "source_count_bucket", "tool_kind"])
    private static let sensitiveKeyFragments = [
        "audio",
        "authorization",
        "bearer",
        "bundle",
        "credential",
        "dsn",
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
    private static let isoDateFormatter = ISO8601DateFormatter()
    private static let storageKey = "observability-anonymous-analytics-id"
    private static let analyticsEnabledKey = "observability-anonymous-analytics-enabled"
    private static let apiKeyInfoKey = "TranscriptedPostHogAPIKey"
    private static let hostInfoKey = "TranscriptedPostHogHost"
    private static let localOverridesFileName = "observability-overrides.plist"
    private static let sessionID = UUID().uuidString

    static func observe(toolName: String, result: CallTool.Result) {
        track(observation(toolName: toolName, result: result))
    }

    static func observation(toolName: String, result: CallTool.Result, clientFamily: String = clientFamily()) -> AgentCaptureQueryObservation {
        let plainText = result.content.compactMap { content -> String? in
            if case .text(let text, _, _) = content {
                return text
            }
            return nil
        }.joined(separator: "\n")

        return AgentCaptureQueryObservation(
            clientFamily: normalizedClientFamily(clientFamily),
            toolKind: toolKind(for: toolName),
            captureKind: captureKind(for: toolName, plainText: plainText),
            result: resultKind(result: result, plainText: plainText),
            sourceCountBucket: sourceCountBucket(for: toolName, result: result, plainText: plainText)
        )
    }

    static func sanitizedProperties(_ observation: AgentCaptureQueryObservation) -> [String: String] {
        sanitizeProperties([
            "capture_kind": observation.captureKind,
            "client_family": observation.clientFamily,
            "result": observation.result,
            "source_count_bucket": observation.sourceCountBucket,
            "tool_kind": observation.toolKind,
        ])
    }

    static func isAnalyticsEnabled(
        userDefaults: UserDefaults = .standard,
        preferencesURL: URL? = defaultAppPreferencesURL()
    ) -> Bool {
        if userDefaults.object(forKey: analyticsEnabledKey) != nil {
            return userDefaults.bool(forKey: analyticsEnabledKey)
        }

        if let preferencesURL,
           let data = try? Data(contentsOf: preferencesURL),
           let plist = try? PropertyListSerialization.propertyList(from: data, options: [], format: nil),
           let preferences = plist as? [String: Any],
           let enabled = preferences[analyticsEnabledKey] as? Bool {
            return enabled
        }

        return true
    }

    private static func track(_ observation: AgentCaptureQueryObservation) {
        guard isAnalyticsEnabled(),
              let apiKey = firstNonEmpty(
                ProcessInfo.processInfo.environment["POSTHOG_API_KEY"],
                localOverrideValue(forKey: apiKeyInfoKey),
                bundleInfoValue(forKey: apiKeyInfoKey)
              ),
              let host = firstNonEmpty(
                ProcessInfo.processInfo.environment["POSTHOG_HOST"],
                localOverrideValue(forKey: hostInfoKey),
                bundleInfoValue(forKey: hostInfoKey)
              ),
              let url = normalizedCaptureURL(from: host) else {
            return
        }

        var properties = defaultProperties()
        for (key, value) in sanitizedProperties(observation) {
            properties[key] = value
        }

        let payload = MCPAnalyticsCaptureRequest(
            apiKey: apiKey,
            event: eventName,
            distinctID: distinctID(),
            timestamp: isoDateFormatter.string(from: Date()),
            properties: properties
        )

        guard let data = try? JSONEncoder().encode(payload) else { return }

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = data

        URLSession.shared.dataTask(with: request).resume()
    }

    private static func defaultProperties() -> [String: String] {
        var properties = [
            "distinct_id": distinctID(),
            "app_version": bundleInfoValue(forKey: "CFBundleShortVersionString") ?? "unknown",
            "build_version": bundleInfoValue(forKey: "CFBundleVersion") ?? "unknown",
            "os_major": "\(ProcessInfo.processInfo.operatingSystemVersion.majorVersion)",
        ]
        let sanitizedSessionID = sanitizeText(sessionID)
        if !sanitizedSessionID.isEmpty {
            properties["session_id"] = sanitizedSessionID
        }
        return properties
    }

    private static func distinctID(userDefaults: UserDefaults = .standard) -> String {
        if let existing = userDefaults.string(forKey: storageKey), !existing.isEmpty {
            return existing
        }

        let newValue = UUID().uuidString
        userDefaults.set(newValue, forKey: storageKey)
        return newValue
    }

    private static func resultKind(result: CallTool.Result, plainText: String) -> String {
        if result.isError == true {
            return "error"
        }
        if plainText.localizedCaseInsensitiveContains("No meetings found")
            || plainText.localizedCaseInsensitiveContains("No dictations found")
            || plainText.localizedCaseInsensitiveContains("No context found")
            || plainText.localizedCaseInsensitiveContains("No recent context found")
            || plainText.localizedCaseInsensitiveContains("No results found") {
            return "no_results"
        }
        return "success"
    }

    private static func sourceCountBucket(for toolName: String, result: CallTool.Result, plainText: String) -> String {
        guard result.isError != true else { return "0" }
        if resultKind(result: result, plainText: plainText) == "no_results" {
            return "0"
        }
        return countBucket(sourceCount(for: toolName, plainText: plainText))
    }

    private static func sourceCount(for toolName: String, plainText: String) -> Int {
        guard let data = plainText.data(using: .utf8) else {
            return plainText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? 0 : 1
        }

        if let array = try? JSONSerialization.jsonObject(with: data) as? [Any] {
            return array.count
        }

        if let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
            if let results = object["results"] as? [Any] { return results.count }
            if let items = object["items"] as? [Any] { return items.count }
            if let meetings = object["meetings"] as? [Any] { return meetings.count }
            if let meetingCount = object["meeting_count"] as? Int { return meetingCount }
        }

        switch toolName {
        case "read_meeting", "read_dictation", "who_is":
            return plainText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? 0 : 1
        default:
            return plainText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? 0 : 1
        }
    }

    private static func countBucket(_ count: Int) -> String {
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

    private static func toolKind(for toolName: String) -> String {
        switch toolName {
        case "list_meetings", "list_dictations":
            return "list"
        case "read_meeting", "read_dictation":
            return "read"
        case "search", "search_context":
            return "search"
        case "recent_context":
            return "recent"
        case "who_is":
            return "who_is"
        case "recap":
            return "recap"
        default:
            return "unknown"
        }
    }

    private static func captureKind(for toolName: String, plainText: String) -> String {
        switch toolName {
        case "list_meetings", "read_meeting", "search", "who_is", "recap":
            return "meeting"
        case "list_dictations", "read_dictation":
            return "dictation"
        case "search_context", "recent_context":
            if plainText.contains(#""kind" : "meeting""#) && plainText.contains(#""kind" : "dictation""#) {
                return "mixed"
            }
            if plainText.contains(#""kind" : "meeting""#) {
                return "meeting"
            }
            if plainText.contains(#""kind" : "dictation""#) {
                return "dictation"
            }
            return "mixed"
        default:
            return "unknown"
        }
    }

    private static func clientFamily() -> String {
        normalizedClientFamily(ProcessInfo.processInfo.environment["TRANSCRIPTED_MCP_CLIENT_FAMILY"] ?? "unknown")
    }

    private static func normalizedClientFamily(_ raw: String) -> String {
        let normalized = raw.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        return allowedClientFamilies.contains(normalized) ? normalized : "unknown"
    }

    private static func sanitizeProperties(_ properties: [String: String]) -> [String: String] {
        var sanitized: [String: String] = [:]
        for (key, value) in properties {
            guard allowedProperties.contains(key), !shouldDrop(key: key) else { continue }
            let cleaned = sanitizeText(value)
            guard !cleaned.isEmpty else { continue }
            sanitized[key] = cleaned
        }
        return sanitized
    }

    private static func sanitizeText(_ text: String) -> String {
        var cleaned = text
        cleaned = cleaned.replacingOccurrences(
            of: #"[A-Z0-9._%+-]+@[A-Z0-9.-]+\.[A-Z]{2,}"#,
            with: "[redacted-email]",
            options: [.regularExpression, .caseInsensitive]
        )
        cleaned = cleaned.replacingOccurrences(
            of: #"https?://\S+"#,
            with: "[redacted-url]",
            options: [.regularExpression, .caseInsensitive]
        )
        cleaned = cleaned.replacingOccurrences(
            of: #"/(?:System/Volumes/Data/)?Users/[^/\s]+(?:/[^\s,;]*)*"#,
            with: "[redacted-path]",
            options: [.regularExpression]
        )
        cleaned = cleaned.replacingOccurrences(
            of: #"(?i)\b(Bearer|Basic)\s+[A-Za-z0-9._~+/\-=]+"#,
            with: "$1 ****",
            options: [.regularExpression]
        )
        cleaned = cleaned.trimmingCharacters(in: .whitespacesAndNewlines)
        if cleaned.count > 80 {
            return String(cleaned.prefix(80)) + "..."
        }
        return cleaned
    }

    private static func shouldDrop(key: String) -> Bool {
        let lower = key.lowercased()
        return sensitiveKeyFragments.contains { lower.contains($0) }
    }

    private static func normalizedCaptureURL(from host: String) -> URL? {
        let trimmedHost = host.trimmingCharacters(in: .whitespacesAndNewlines)
            .trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        guard trimmedHost.lowercased().hasPrefix("https://") else {
            return nil
        }
        return URL(string: "\(trimmedHost)/capture/")
    }

    private static func localOverrideValue(forKey key: String) -> String? {
        for url in localOverridesSearchURLs() {
            guard let data = try? Data(contentsOf: url),
                  let plist = try? PropertyListSerialization.propertyList(from: data, options: [], format: nil),
                  let overrides = plist as? [String: String] else {
                continue
            }
            if let value = firstNonEmpty(overrides[key]) {
                return value
            }
        }
        return nil
    }

    private static func localOverridesSearchURLs() -> [URL] {
        let appSupport = applicationSupportDirectory()
        return [
            appSupport
                .appendingPathComponent("Transcripted", isDirectory: true)
                .appendingPathComponent(localOverridesFileName),
            appSupport
                .appendingPathComponent("Draft", isDirectory: true)
                .appendingPathComponent(localOverridesFileName),
        ]
    }

    private static func bundleInfoValue(forKey key: String) -> String? {
        if let value = Bundle.main.object(forInfoDictionaryKey: key) as? String, !value.isEmpty {
            return value
        }

        for url in companionInfoPlistCandidates() {
            guard let data = try? Data(contentsOf: url),
                  let plist = try? PropertyListSerialization.propertyList(from: data, options: [], format: nil),
                  let info = plist as? [String: Any],
                  let value = info[key] as? String,
                  !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                continue
            }
            return value
        }
        return nil
    }

    private static func companionInfoPlistCandidates() -> [URL] {
        var candidates: [URL] = []
        var current = URL(fileURLWithPath: CommandLine.arguments.first ?? "")
            .standardizedFileURL
            .deletingLastPathComponent()

        for _ in 0..<6 {
            candidates.append(current.appendingPathComponent("Info.plist"))
            candidates.append(current.appendingPathComponent("Contents/Info.plist"))
            current.deleteLastPathComponent()
        }

        candidates.append(URL(fileURLWithPath: FileManager.default.currentDirectoryPath).appendingPathComponent("Info.plist"))
        return candidates
    }

    private static func defaultAppPreferencesURL() -> URL? {
        let library = FileManager.default.urls(for: .libraryDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent("Library", isDirectory: true)
        return library
            .appendingPathComponent("Preferences", isDirectory: true)
            .appendingPathComponent("com.justinbetker.draft.plist", isDirectory: false)
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
