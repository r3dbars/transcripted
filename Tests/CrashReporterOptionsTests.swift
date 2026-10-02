import Foundation

/// The Sentry SDK options that decide what leaves the device. Each one is a
/// privacy or noise boundary; dropping one silently widens what the SDK
/// reports on its own.
func testCrashReporterOptions() {
    runSuite("CrashReporter keeps the SDK's automatic reporting switched off") {
        var options = FakeSentryPrivacyOptions()
        CrashReporterPrivacyOptions.apply(to: &options)

        assertFalse(options.sendDefaultPii, "Sentry must not attach default PII")
        assertFalse(options.enableAutoSessionTracking, "sessions start only after the crash-reporting choice")
        assertFalse(options.enableNetworkBreadcrumbs, "network requests must not become breadcrumbs")
        assertEqual(options.maxBreadcrumbs, UInt(0), "no breadcrumbs are kept")
        assertFalse(options.attachStacktrace, "non-crash events must not carry stack traces")
        assertFalse(
            options.enableCaptureFailedRequests,
            "URLSession 5xx responses must not each become a Sentry issue"
        )
    }
}

/// Starts with every switch at the SDK's permissive value so a missing line
/// in `apply` shows up as a failure.
private struct FakeSentryPrivacyOptions: SentryPrivacyOptionsSettable {
    var sendDefaultPii = true
    var enableAutoSessionTracking = true
    var enableNetworkBreadcrumbs = true
    var maxBreadcrumbs: UInt = 100
    var attachStacktrace = true
    var enableCaptureFailedRequests = true
}
