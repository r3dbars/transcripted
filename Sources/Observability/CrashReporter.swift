// CrashReporter.swift
// Privacy-safe Sentry reporting via the official SDK with aggressive scrubbing.
//
// HOW IT WORKS:
//   1. Reads Sentry DSN/config from Info.plist or process environment.
//   2. Uses the official Sentry crash handler for stronger crash capture.
//   3. Scrubs strings, tags, extras, contexts, requests, and breadcrumbs before send.

import Foundation
import Sentry

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
        options.enableAppHangTracking = SentryRuntimeConfiguration.appHangTrackingEnabled()
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
            // Keyed "detail", not "context": "context" is a sensitive-key fragment in
            // SentryPayloadSanitizer, so that key would be dropped before send.
            extra["detail"] = context
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

    static func setRuntimeDiagnosticsContext(_ context: [String: String]) {
        guard Self.isAvailable, CrashReportingPreferences.isEnabled() else { return }

        let sanitizedContext = SentryPayloadSanitizer.sanitizeContext(context)
        guard !sanitizedContext.isEmpty else { return }
        let sanitizedTags = SentryPayloadSanitizer.sanitizeCrashRuntimeTags(context)

        SentrySDK.configureScope { scope in
            scope.setContext(value: sanitizedContext, key: "runtime")
            if !sanitizedTags.isEmpty {
                scope.setTags(sanitizedTags)
            }
        }
    }

    @discardableResult
    func captureSupportDiagnosticEvent(extra: [String: String]) -> String? {
        captureMessageEvent(
            level: .warning,
            title: "support_diagnostic_event",
            message: "Manual support diagnostic event from Transcripted Settings",
            tags: [
                "source": "support_diagnostics",
                "engine": "support",
                "event": "diagnostic_event",
            ],
            extra: extra,
            fingerprint: ["support", "diagnostic_event"]
        )
    }

    func captureObservabilityEvent(
        level: EventLevel,
        engine: String,
        event: String,
        message: String,
        context: [String: String]
    ) {
        let diagnosticTags = SentryEventPolicy.diagnosticTags(
            forEngine: engine,
            event: event,
            context: context
        )
        let tags = [
            "source": "observability",
            "engine": engine,
            "event": event,
        ].merging(diagnosticTags) { current, _ in current }

        // Extras carry only the allowlist-filtered diagnostic subset. The full
        // merged context can hold free-text values under innocuous keys (engine
        // state snapshots, device names), and the off-device contract is
        // allowlist-gated, not just key-drop + redaction.
        _ = captureMessageEvent(
            level: sentryLevel(for: level),
            title: "\(engine).\(event)",
            message: message,
            tags: tags,
            extra: diagnosticTags,
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
                if let module = exception.module {
                    exception.module = SentryPayloadSanitizer.sanitizeText(module)
                }
                sanitize(stacktrace: exception.stacktrace)
            }
        }

        if let threads = event.threads {
            for thread in threads {
                if let name = thread.name {
                    thread.name = SentryPayloadSanitizer.sanitizeText(name)
                }
                sanitize(stacktrace: thread.stacktrace)
            }
        }

        sanitize(stacktrace: event.stacktrace)
        if let debugMeta = event.debugMeta {
            for debugImage in debugMeta {
                debugImage.codeFile = nil
            }
        }

        event.request = nil
        event.user = nil
        event.breadcrumbs = nil
        event.serverName = nil

        return event
    }

    private func sanitize(stacktrace: SentryStacktrace?) {
        guard let stacktrace else { return }
        stacktrace.registers = [:]

        for frame in stacktrace.frames {
            frame.fileName = nil
            frame.contextLine = nil
            frame.preContext = nil
            frame.postContext = nil
            frame.vars = nil

            if let function = frame.function {
                frame.function = SentryPayloadSanitizer.sanitizeText(function)
            }
            if let module = frame.module {
                frame.module = SentryPayloadSanitizer.sanitizeText(module)
            }
            frame.package = nil
        }
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
