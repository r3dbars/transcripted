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
        for option in pinnedOptions {
            assertTrue(source.contains(option), "CrashReporter should keep `\(option)`")
        }
    }
}

private func repoRoot() -> URL {
    URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent()
        .deletingLastPathComponent()
}
