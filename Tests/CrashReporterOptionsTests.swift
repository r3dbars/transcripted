import Foundation

/// Pins the Sentry SDK options that decide what leaves the device. Each line
/// here is a privacy or noise boundary; a refactor that drops one silently
/// widens what the SDK reports on its own.
func testCrashReporterOptions() {
    runSuite("CrashReporter keeps the SDK's automatic reporting switched off") {
        let source = (try? String(
            contentsOf: repoRoot().appendingPathComponent("Sources/Observability/CrashReporter.swift"),
            encoding: .utf8
        )) ?? ""
        assertFalse(source.isEmpty, "CrashReporter.swift should be readable from the repo root")

        let pinnedOptions = [
            "options.sendDefaultPii = false",
            "options.enableAutoSessionTracking = false",
            "options.enableNetworkBreadcrumbs = false",
            "options.maxBreadcrumbs = 0",
            "options.attachStacktrace = false",
            // Every URLSession 5xx used to become its own Sentry issue
            // (`HTTPClientError ... 503`) with no URL attached: appcast or
            // analytics endpoints having a bad hour, filed as app errors.
            "options.enableCaptureFailedRequests = false",
        ]
        // Each option must be a live statement: exactly one occurrence, on a
        // line that is not commented out. A commented-out or duplicated
        // assignment (for example a later `= true`) fails here.
        let liveLines = source
            .split(separator: "\n", omittingEmptySubsequences: false)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.hasPrefix("//") }
        for option in pinnedOptions {
            let matches = liveLines.filter { $0 == option }.count
            assertEqual(matches, 1, "CrashReporter should set `\(option)` exactly once as live code")
            let prefix = option.components(separatedBy: " = ")[0] + " = "
            let assignments = liveLines.filter { $0.hasPrefix(prefix) }.count
            assertEqual(assignments, 1, "`\(prefix)` must not be assigned again elsewhere in CrashReporter")
        }
    }
}

private func repoRoot() -> URL {
    URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent()
        .deletingLastPathComponent()
}
