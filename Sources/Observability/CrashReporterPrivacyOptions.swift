// CrashReporterPrivacyOptions.swift
// The Sentry SDK switches that decide what leaves the device on their own.
// Each one is a privacy or noise boundary; CrashReporter applies them to the
// SDK options before SentrySDK.start. Kept free of `import Sentry` so the fast
// tests can check the values against a fake.

import Foundation

/// The six Sentry `Options` properties CrashReporter must turn off.
/// `Sentry.Options` conforms in CrashReporter.swift.
protocol SentryPrivacyOptionsSettable {
    var sendDefaultPii: Bool { get set }
    var enableAutoSessionTracking: Bool { get set }
    var enableNetworkBreadcrumbs: Bool { get set }
    var maxBreadcrumbs: UInt { get set }
    var attachStacktrace: Bool { get set }
    var enableCaptureFailedRequests: Bool { get set }
}

enum CrashReporterPrivacyOptions {
    static func apply(to options: inout some SentryPrivacyOptionsSettable) {
        options.sendDefaultPii = false
        // Session tracking is started explicitly after onboarding and when the
        // user changes the crash-reporting preference. That keeps the first-run
        // choice and later opt-outs aligned with Release Health envelopes.
        options.enableAutoSessionTracking = false
        options.enableNetworkBreadcrumbs = false
        options.maxBreadcrumbs = 0
        options.attachStacktrace = false
        // The SDK otherwise files every URLSession 5xx as its own error issue
        // (`HTTPClientError: HTTP Client Error with status code: 503`) with no
        // URL attached. Those are the appcast or analytics endpoints having a
        // bad hour, not app failures, and they bury the real issues.
        options.enableCaptureFailedRequests = false
    }
}
