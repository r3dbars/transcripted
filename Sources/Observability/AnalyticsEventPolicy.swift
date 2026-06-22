import Foundation

/// Privacy allowlist for anonymous PostHog analytics events.
///
/// The event-to-property registry is single-sourced from
/// `Resources/analytics-events.psv` (one `event_name|prop,prop,...` line per
/// event). That data file is marked `merge=union` in `.gitattributes`, so two
/// telemetry PRs that each add a new event append independent lines instead of
/// colliding on a shared multi-line Swift dictionary anchor. This file compiles
/// the data into the allowlist the rest of the app consumes.
struct AnalyticsEventPolicy: Equatable {
    let name: String
    let allowedProperties: Set<String>

    static func policy(forEvent event: String) -> AnalyticsEventPolicy? {
        allowedPolicies[event]
    }

    /// All allowlisted analytics event names, sorted. Exposed so tests can assert
    /// source-vs-docs parity against the compiled policy table instead of parsing this file's text.
    static var allEventNames: [String] {
        allowedPolicies.keys.sorted()
    }

    /// All allowlisted analytics policies, sorted by event name. Tests use this
    /// to keep the public taxonomy doc in lockstep with the compiled allowlist.
    static var allPolicies: [AnalyticsEventPolicy] {
        allowedPolicies.keys.sorted().compactMap { allowedPolicies[$0] }
    }

    private static let allowedPolicies: [String: AnalyticsEventPolicy] =
        parse(registry: loadRegistryText() ?? "")

    static func parse(registry text: String) -> [String: AnalyticsEventPolicy] {
        var table: [String: AnalyticsEventPolicy] = [:]

        for rawLine in text.split(separator: "\n", omittingEmptySubsequences: true) {
            let line = rawLine.trimmingCharacters(in: .whitespaces)
            guard !line.isEmpty, !line.hasPrefix("#"), let pipe = line.firstIndex(of: "|") else {
                continue
            }

            let name = String(line[..<pipe]).trimmingCharacters(in: .whitespaces)
            guard !name.isEmpty else { continue }

            let properties = line[line.index(after: pipe)...]
                .split(separator: ",")
                .map { $0.trimmingCharacters(in: .whitespaces) }
                .filter { !$0.isEmpty }
            table[name] = AnalyticsEventPolicy(name: name, allowedProperties: Set(properties))
        }

        return table
    }

    private static let registryResourceName = "analytics-events"
    private static let registryResourceExtension = "psv"

    private static func loadRegistryText() -> String? {
        if let url = Bundle.main.url(
            forResource: registryResourceName,
            withExtension: registryResourceExtension
        ), let text = try? String(contentsOf: url, encoding: .utf8) {
            return text
        }

        let relativePath = "Resources/\(registryResourceName).\(registryResourceExtension)"

        let cwdURL = URL(fileURLWithPath: FileManager.default.currentDirectoryPath, isDirectory: true)
            .appendingPathComponent(relativePath)
        if let text = try? String(contentsOf: cwdURL, encoding: .utf8) {
            return text
        }

        let repoRootURL = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent(relativePath)
        return try? String(contentsOf: repoRootURL, encoding: .utf8)
    }
}
