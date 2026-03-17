import Foundation
#if canImport(Sentry)
import Sentry
#endif

/// Manages opt-in crash reporting via Sentry.
/// Respects user consent — disabled by default, toggled in Settings.
enum CrashReporting {

    /// UserDefaults key for crash reporting consent
    static let consentKey = "crashReportingEnabled"

    /// Whether the user has opted in to crash reporting
    static var isEnabled: Bool {
        UserDefaults.standard.bool(forKey: consentKey)
    }

    /// Initialize Sentry if the user has opted in.
    /// Call once during app startup.
    static func initialize() {
        guard isEnabled else {
            AppLogger.app.info("Crash reporting disabled (user opt-out)")
            return
        }

        #if canImport(Sentry)
        SentrySDK.start { options in
            options.dsn = "SENTRY_DSN_PLACEHOLDER"
            options.tracesSampleRate = 0.2
            options.profilesSampleRate = 0.1
            options.enableAutoSessionTracking = true
            options.enableCrashHandler = true
            options.enableAutoPerformanceTracing = true
            options.attachScreenshot = false  // Privacy: no screenshots
            options.attachViewHierarchy = false

            // Set release version for tracking
            let version = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "unknown"
            let build = Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "unknown"
            options.releaseName = "com.transcripted.app@\(version)+\(build)"

            // Privacy: strip PII from events
            options.beforeSend = { event in
                event.user = nil
                return event
            }
        }
        AppLogger.app.info("Crash reporting initialized (Sentry)")
        #else
        AppLogger.app.info("Crash reporting enabled but Sentry not available (not linked)")
        #endif
    }

    /// Update consent and restart/stop Sentry accordingly
    static func setEnabled(_ enabled: Bool) {
        UserDefaults.standard.set(enabled, forKey: consentKey)

        #if canImport(Sentry)
        if enabled {
            initialize()
        } else {
            SentrySDK.close()
            AppLogger.app.info("Crash reporting disabled by user")
        }
        #endif
    }

    /// Capture a non-fatal error for tracking
    static func captureError(_ error: Error, context: [String: String] = [:]) {
        #if canImport(Sentry)
        guard isEnabled else { return }
        let sentryError = error as NSError
        SentrySDK.capture(error: sentryError) { scope in
            for (key, value) in context {
                scope.setExtra(value: value, key: key)
            }
        }
        #endif
    }

    /// Add a breadcrumb for debugging context
    static func addBreadcrumb(category: String, message: String) {
        #if canImport(Sentry)
        guard isEnabled else { return }
        let crumb = Breadcrumb()
        crumb.category = category
        crumb.message = message
        crumb.level = .info
        SentrySDK.addBreadcrumb(crumb)
        #endif
    }
}
