// CrashReporterPrivacyOptions.swift
// The Sentry SDK switches that decide what leaves the device on their own.
// Each one is a privacy or noise boundary; CrashReporter applies them to the
// SDK options before SentrySDK.start. Kept free of `import Sentry` so the fast
// tests can check the values against a fake.

import Foundation

/// The Sentry `Options` properties CrashReporter must turn off before the
/// session-tracking builder runs. Auto session tracking starts false here so
/// a caller that only applies privacy options cannot send sessions before the
/// crash-reporting choice; `SentrySDKOptionsBuilder` then turns it on when
/// that choice is already on. `Sentry.Options` conforms in CrashReporter.swift.
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
        // Fail closed: the SDK default is on. The options builder turns this
        // back on only after onboarding, and only while crash reporting is on.
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
