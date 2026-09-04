import Foundation

/// Pins the Sentry SDK options that decide what leaves the device. Each line
/// here is a privacy or noise boundary; a refactor that drops one silently
/// widens what the SDK reports on its own.
func testCrashReporterOptions() {
    runSuite("CrashReporter keeps the SDK's automatic reporting switched off") {
        let raw = (try? String(
            contentsOf: repoRoot().appendingPathComponent("Sources/Observability/CrashReporter.swift"),
            encoding: .utf8
        )) ?? ""
        assertFalse(raw.isEmpty, "CrashReporter.swift should be readable from the repo root")

        // Only code that actually runs counts: block comments and
        // `#if false` regions are stripped, line comments are skipped.
        let liveLines = liveSourceLines(raw)
        let startIndex = liveLines.firstIndex { $0.hasPrefix("SentrySDK.start(") }
        assertTrue(startIndex != nil, "CrashReporter should start the SDK exactly where the options are applied")

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
        for option in pinnedOptions {
            let occurrences = liveLines.indices.filter { liveLines[$0] == option }
            assertEqual(occurrences.count, 1, "CrashReporter should set `\(option)` exactly once as live code")

            let property = option.components(separatedBy: " = ")[0] + " = "
            let assignments = liveLines.filter { $0.hasPrefix(property) }.count
            assertEqual(assignments, 1, "`\(property)` must not be assigned again elsewhere in CrashReporter")

            if let optionIndex = occurrences.first, let startIndex {
                assertTrue(
                    optionIndex < startIndex,
                    "`\(option)` must be applied before SentrySDK.start or the SDK never sees it"
                )
            }
        }
    }
}

/// Source lines that can execute: `/* ... */` blocks and `#if false ... #endif`
/// regions removed, then trimmed, with `//` line comments dropped.
private func liveSourceLines(_ text: String) -> [String] {
    var stripped = text
    while let open = stripped.range(of: "/*"),
          let close = stripped.range(of: "*/", range: open.upperBound..<stripped.endIndex) {
        stripped.removeSubrange(open.lowerBound..<close.upperBound)
    }
    var lines: [String] = []
    var insideDisabledBlock = false
    for line in stripped.split(separator: "\n", omittingEmptySubsequences: false) {
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        if trimmed.hasPrefix("#if false") {
            insideDisabledBlock = true
            continue
        }
        if insideDisabledBlock {
            if trimmed.hasPrefix("#endif") { insideDisabledBlock = false }
            continue
        }
        if trimmed.hasPrefix("//") { continue }
        lines.append(trimmed)
    }
    return lines
}

private func repoRoot() -> URL {
    URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent()
        .deletingLastPathComponent()
}
