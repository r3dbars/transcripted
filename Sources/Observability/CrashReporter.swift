// CrashReporter.swift
// Privacy-safe Sentry reporting via the official SDK with aggressive scrubbing.
//
// HOW IT WORKS:
//   1. Reads Sentry DSN/config from Info.plist or process environment.
//   2. Uses the official Sentry crash handler for stronger crash capture.
//   3. Scrubs strings, tags, extras, contexts, requests, and breadcrumbs before send.

import Foundation
import Sentry

private enum SentryRuntimeConfiguration {
    static let dsnInfoKey = "TranscriptedSentryDSN"
    static let environmentInfoKey = "TranscriptedSentryEnvironment"

    static func dsn() -> String? {
        firstNonEmpty(
            Bundle.main.object(forInfoDictionaryKey: dsnInfoKey) as? String,
            ProcessInfo.processInfo.environment["SENTRY_DSN"]
        )
    }

    static func environment() -> String {
        firstNonEmpty(
            Bundle.main.object(forInfoDictionaryKey: environmentInfoKey) as? String,
            ProcessInfo.processInfo.environment["SENTRY_ENVIRONMENT"]
        ) ?? "production"
    }

    static func releaseName() -> String {
        let version = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "unknown"
        return "transcripted@\(version)"
    }

    static func dist() -> String? {
        firstNonEmpty(Bundle.main.infoDictionary?["CFBundleVersion"] as? String)
    }

    private static func firstNonEmpty(_ candidates: String?...) -> String? {
        candidates
            .compactMap { $0?.trimmingCharacters(in: .whitespacesAndNewlines) }
            .first(where: { !$0.isEmpty })
    }
}

final class CrashReporter {
    static let shared = CrashReporter()

    static var isAvailable: Bool {
        SentryRuntimeConfiguration.dsn() != nil
    }

    private init() {}

    private var hasStarted = false

    static func setup(dsn: String? = SentryRuntimeConfiguration.dsn()) {
        guard let dsn, !shared.hasStarted else { return }

        let options = Options()
        options.dsn = dsn
        options.environment = SentryRuntimeConfiguration.environment()
        options.releaseName = SentryRuntimeConfiguration.releaseName()
        options.dist = SentryRuntimeConfiguration.dist()
        options.sendDefaultPii = false
        options.enableCrashHandler = true
        options.enableUncaughtNSExceptionReporting = true
        options.enableAutoSessionTracking = false
        options.enableNetworkBreadcrumbs = false
        options.maxBreadcrumbs = 0
        options.attachStacktrace = false
        options.beforeBreadcrumb = { _ in nil }
        options.beforeCaptureScreenshot = { _ in false }
        options.beforeCaptureViewHierarchy = { _ in false }
        options.beforeSend = { event in
            guard CrashReportingPreferences.isEnabled() else { return nil }
            return shared.sanitize(event: event)
        }

        SentrySDK.start(options: options)

        shared.hasStarted = true
    }

    func capture(error: Error, context: String = "") {
        var extra: [String: String] = [:]
        if !context.isEmpty {
            extra["context"] = context
        }

        _ = captureMessageEvent(
            level: .error,
            title: String(describing: type(of: error)),
            message: "Swift error captured",
            tags: ["source": "swift_error"],
            extra: extra
        )
    }

    func capture(message: String, level: String = "warning", extra: [String: String] = [:]) {
        _ = captureMessageEvent(
            level: sentryLevel(for: level),
            title: message,
            message: message,
            tags: ["source": "manual_message"],
            extra: extra
        )
    }

    func captureObservabilityEvent(
        level: EventLevel,
        engine: String,
        event: String,
        message: String,
        context: [String: String]
    ) {
        _ = captureMessageEvent(
            level: sentryLevel(for: level),
            title: "\(engine).\(event)",
            message: message,
            tags: [
                "source": "observability",
                "engine": engine,
                "event": event,
            ],
            extra: context,
            fingerprint: [engine, event]
        )
    }

    @discardableResult
    func sendTestEvent() -> String? {
        captureMessageEvent(
            level: .warning,
            title: "sentry_test_event",
            message: "Manual Sentry verification from Transcripted Settings",
            tags: [
                "source": "manual_test",
                "engine": "settings",
                "event": "sentry_test_event",
            ],
            extra: [
                "recommended_check": "Search for sentry_test_event in the Sentry issue list",
            ],
            fingerprint: ["settings", "sentry_test_event"]
        )
    }

    @discardableResult
    private func captureMessageEvent(
        level: SentryLevel,
        title: String,
        message: String,
        tags: [String: String] = [:],
        extra: [String: String] = [:],
        fingerprint: [String]? = nil
    ) -> String? {
        guard Self.isAvailable, CrashReportingPreferences.isEnabled() else { return nil }

        let sanitizedTitle = SentryPayloadSanitizer.sanitizeText(title)
        let sanitizedMessage = SentryPayloadSanitizer.sanitizeText(message)
        let sanitizedTags = SentryPayloadSanitizer.sanitizeTags(tags)
        let sanitizedExtra = SentryPayloadSanitizer.sanitizeContext(extra)

        let sentryID = SentrySDK.capture(message: "\(sanitizedTitle): \(sanitizedMessage)") { scope in
            scope.clearBreadcrumbs()
            scope.setLevel(level)
            scope.setTags(sanitizedTags)
            scope.setExtras(sanitizedExtra)
            if let fingerprint, !fingerprint.isEmpty {
                scope.setFingerprint(fingerprint)
            }
            scope.setContext(
                value: [
                    "app_name": "Transcripted",
                    "app_version": Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "unknown",
                ],
                key: "reporter"
            )
        }

        return sentryID.sentryIdString
    }

    private func sanitize(event: Event) -> Event {
        if let message = event.message {
            let formatted = SentryPayloadSanitizer.sanitizeText(message.formatted)
            let sanitizedMessage = SentryMessage(formatted: formatted)
            sanitizedMessage.message = message.message.map(SentryPayloadSanitizer.sanitizeText)
            event.message = sanitizedMessage
        }

        if let tags = event.tags {
            event.tags = SentryPayloadSanitizer.sanitizeTags(tags)
        }

        if let extra = event.extra {
            event.extra = SentryPayloadSanitizer.sanitizeAnyDictionary(extra)
        }

        if let context = event.context {
            event.context = SentryPayloadSanitizer.sanitizeEventContexts(context)
        }

        if let exceptions = event.exceptions {
            for exception in exceptions {
                if let value = exception.value {
                    exception.value = SentryPayloadSanitizer.sanitizeText(value)
                }
                if let type = exception.type {
                    exception.type = SentryPayloadSanitizer.sanitizeText(type)
                }
            }
        }

        event.request = nil
        event.user = nil
        event.breadcrumbs = nil
        event.serverName = nil

        return event
    }

    private func sentryLevel(for level: EventLevel) -> SentryLevel {
        switch level {
        case .error:
            return .error
        case .warning:
            return .warning
        case .info:
            return .info
        }
    }

    private func sentryLevel(for level: String) -> SentryLevel {
        switch level.lowercased() {
        case "fatal":
            return .fatal
        case "error":
            return .error
        case "info":
            return .info
        default:
            return .warning
        }
    }
}
