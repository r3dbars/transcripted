import Foundation

/// Identity, privacy, and session-tracking fields `CrashReporter` sets on
/// Sentry `Options` before `SentrySDK.start`. `Sentry.Options` conforms in
/// `CrashReporter.swift` so tests apply this to a fake.
protocol SentrySDKOptionsSettable: SentryPrivacyOptionsSettable {
    var environment: String { get set }
    var releaseName: String? { get set }
    var dist: String? { get set }
    var sessionTrackingIntervalMillis: UInt { get set }
}

enum SentrySDKOptionsBuilder {
    /// Release, dist, and environment use the same `SentryRuntimeConfiguration`
    /// values the release-packaging scripts register, so sessions group with
    /// crash events per shipped build. Privacy switches stay off. Auto session
    /// tracking is on only when onboarding is done and crash reporting is on.
    static func apply(
        to options: inout some SentrySDKOptionsSettable,
        environment: [String: String] = ProcessInfo.processInfo.environment,
        infoDictionary: [String: Any]? = Bundle.main.infoDictionary,
        onboardingCompleted: Bool,
        crashReportingEnabled: Bool
    ) {
        options.environment = SentryRuntimeConfiguration.environment(
            environment: environment,
            infoDictionary: infoDictionary
        )
        options.releaseName = SentryRuntimeConfiguration.releaseName(
            environment: environment,
            infoDictionary: infoDictionary
        )
        options.dist = SentryRuntimeConfiguration.dist(
            environment: environment,
            infoDictionary: infoDictionary
        )
        CrashReporterPrivacyOptions.apply(to: &options)
        options.enableAutoSessionTracking = SentrySessionTrackingPolicy.enableAutoSessionTracking(
            onboardingCompleted: onboardingCompleted,
            crashReportingEnabled: crashReportingEnabled
        )
        options.sessionTrackingIntervalMillis = SentrySessionTrackingPolicy.backgroundIntervalMillis
    }
}
