import Foundation

/// When the Sentry SDK may run its automatic session tracker, and how long a
/// menu-bar app can sit in the background before that tracker starts a new
/// session.
///
/// Auto tracking starts a session as soon as the SDK starts and the app is
/// (or becomes) active. That is only safe once onboarding has recorded the
/// crash-reporting choice and that choice is on. Fresh installs and opt-outs
/// keep it off; `SentrySessionRotator` still starts and ends sessions after
/// the choice is settled.
enum SentrySessionTrackingPolicy {
    /// One day, in milliseconds. Matches `SentrySessionRotationPolicy.maxSessionAge`
    /// so the SDK's background timeout does not chop a meeting-recording menu
    /// bar process into 30-second sessions.
    static let backgroundIntervalMillis: UInt = 86_400_000

    static func enableAutoSessionTracking(
        onboardingCompleted: Bool,
        crashReportingEnabled: Bool
    ) -> Bool {
        onboardingCompleted && crashReportingEnabled
    }
}
