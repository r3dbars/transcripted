import Foundation

/// Crash-free session rates only mean something if sessions carry the same
/// release as crash events, start only after the crash-reporting choice, and
/// last a stretch of use instead of 30 seconds in the background.
func testSentrySDKOptionsBuilder() {
    runSuite("automatic session tracking stays off until onboarding and crash reporting are both on") {
        assertFalse(
            SentrySessionTrackingPolicy.enableAutoSessionTracking(
                onboardingCompleted: false,
                crashReportingEnabled: true
            ),
            "a first launch must not send sessions before the crash-reporting choice"
        )
        assertFalse(
            SentrySessionTrackingPolicy.enableAutoSessionTracking(
                onboardingCompleted: true,
                crashReportingEnabled: false
            ),
            "an explicit opt-out must not send sessions"
        )
        assertTrue(
            SentrySessionTrackingPolicy.enableAutoSessionTracking(
                onboardingCompleted: true,
                crashReportingEnabled: true
            ),
            "a returning opted-in install should send Release Health sessions"
        )
    }

    runSuite("the SDK background timeout matches a one-day menu-bar session") {
        assertEqual(
            SentrySessionTrackingPolicy.backgroundIntervalMillis,
            UInt(86_400_000),
            "auto tracking must not end a session after 30 seconds in the background"
        )
        assertEqual(
            SentrySessionTrackingPolicy.backgroundIntervalMillis,
            UInt(SentrySessionRotationPolicy.maxSessionAge * 1_000),
            "the SDK timeout and the sleep/wake rotator should share the same day-long window"
        )
    }

    runSuite("the options builder groups sessions with crash events and respects the crash-reporting choice") {
        let info: [String: Any] = [
            SentryRuntimeConfiguration.environmentInfoKey: "production",
            SentryRuntimeConfiguration.releasePrefixInfoKey: "transcripted",
            "CFBundleShortVersionString": "1.2.3",
            "CFBundleVersion": "456",
        ]

        var allowed = FakeSentrySDKOptions()
        SentrySDKOptionsBuilder.apply(
            to: &allowed,
            environment: [:],
            infoDictionary: info,
            onboardingCompleted: true,
            crashReportingEnabled: true
        )
        assertEqual(allowed.environment, "production", "sessions should use the same environment as crash events")
        assertEqual(allowed.releaseName, "transcripted@1.2.3", "sessions should use the shipped release name")
        assertEqual(allowed.dist, "456", "sessions should use CFBundleVersion as dist")
        assertTrue(allowed.enableAutoSessionTracking, "opted-in launches should enable the SDK session tracker")
        assertEqual(
            allowed.sessionTrackingIntervalMillis,
            SentrySessionTrackingPolicy.backgroundIntervalMillis,
            "the menu-bar background interval should be set on the SDK options"
        )
        assertFalse(allowed.sendDefaultPii, "privacy switches still apply when sessions are on")

        var firstRun = FakeSentrySDKOptions()
        SentrySDKOptionsBuilder.apply(
            to: &firstRun,
            environment: [:],
            infoDictionary: info,
            onboardingCompleted: false,
            crashReportingEnabled: true
        )
        assertFalse(firstRun.enableAutoSessionTracking, "first-run must keep auto sessions off")
        assertEqual(firstRun.releaseName, "transcripted@1.2.3", "first-run crash events still get a release name")
        assertEqual(
            firstRun.sessionTrackingIntervalMillis,
            SentrySessionTrackingPolicy.backgroundIntervalMillis,
            "the interval is set even while auto tracking is off, so a later opt-in does not inherit 30 seconds"
        )

        var optedOut = FakeSentrySDKOptions()
        SentrySDKOptionsBuilder.apply(
            to: &optedOut,
            environment: [:],
            infoDictionary: info,
            onboardingCompleted: true,
            crashReportingEnabled: false
        )
        assertFalse(optedOut.enableAutoSessionTracking, "opted-out launches must not enable the SDK session tracker")
    }
}

/// Starts at the SDK's permissive defaults so a missing builder line shows up.
private struct FakeSentrySDKOptions: SentrySDKOptionsSettable {
    var environment = "unset"
    var releaseName: String? = "unset@0"
    var dist: String? = "unset"
    var sendDefaultPii = true
    var enableAutoSessionTracking = true
    var enableNetworkBreadcrumbs = true
    var maxBreadcrumbs: UInt = 100
    var attachStacktrace = true
    var enableCaptureFailedRequests = true
    var sessionTrackingIntervalMillis: UInt = 30_000
}
