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
    private var sessionTrackingEnabled = false

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
        // Session tracking is started explicitly after onboarding and when the
        // user changes the crash-reporting preference. That keeps the first-run
        // choice and later opt-outs aligned with Release Health envelopes.
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

        installUnrecognizedSelectorCapture()
    }

    /// Starts or ends the current Release Health session after the preference
    /// is settled. Fresh installs stay session-free until onboarding completes.
    static func applySessionTrackingPreference() {
        guard shared.hasStarted else { return }

        let shouldTrack = CrashReportingPreferences.isEnabled()
        guard shouldTrack != shared.sessionTrackingEnabled else { return }

        shared.sessionTrackingEnabled = shouldTrack
        if shouldTrack {
            SentrySDK.startSession()
        } else {
            SentrySDK.endSession()
        }
    }

    /// Ends an opted-in session before normal app termination so Release
    /// Health receives a completed session rather than only a later abnormal
    /// session marker.
    static func endSession() {
        guard shared.sessionTrackingEnabled else { return }
        shared.sessionTrackingEnabled = false
        SentrySDK.endSession()
    }

    // MARK: - Unrecognized-selector enrichment

    // Sentry's `enableUncaughtNSExceptionReporting` records that an
    // NSInvalidArgumentException occurred but not its `reason`, so AppKit
    // target/action faults arrive as "unrecognized selector sent to NSButton"
    // with no class/selector — undiagnosable on the dashboard. We chain an
    // uncaught-exception handler that lifts the (non-PII) class + selector onto
    // the Sentry scope so they ride on the very crash event, then forward to
    // whatever handler was already installed (Sentry's) so crash reporting is
    // fully preserved — never replaced or disabled.
    private static nonisolated(unsafe) var previousUncaughtHandler: NSUncaughtExceptionHandler?
    private static nonisolated(unsafe) var hasInstalledSelectorCapture = false

    private static func installUnrecognizedSelectorCapture() {
        guard !hasInstalledSelectorCapture else { return }
        hasInstalledSelectorCapture = true
        previousUncaughtHandler = NSGetUncaughtExceptionHandler()
        NSSetUncaughtExceptionHandler(transcriptedUnrecognizedSelectorHandler)
    }

    /// Forward to whatever uncaught handler was installed before us (Sentry's),
    /// preserving the existing crash-reporting path.
    static func forwardUncaughtException(_ exception: NSException) {
        previousUncaughtHandler?(exception)
    }

    // `capture(error:)` and `capture(message:)` forwarded arbitrary
    // error/message text to Sentry gated only by text sanitization, with no
    // positive event allowlist (unlike `captureObservabilityEvent`). They have
    // no callers anywhere in the app target, so rather than keep an
    // allowlist-bypassing path alive we make them inert no-ops. If a real need
    // for ad-hoc error capture returns, route it through `SentryEventPolicy`
    // like `captureObservabilityEvent` instead of re-enabling these.
    @available(*, deprecated, message: "Unused; allowlist-bypassing. Route new error capture through captureObservabilityEvent + SentryEventPolicy.")
    func capture(error: Error, context: String = "") {
        _ = error
        _ = context
    }

    @available(*, deprecated, message: "Unused; allowlist-bypassing. Route new message capture through captureObservabilityEvent + SentryEventPolicy.")
    func capture(message: String, level: String = "warning", extra: [String: String] = [:]) {
        _ = message
        _ = level
        _ = extra
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
        // Support-diagnostic extras are built from app state and can pick up
        // free-text values under innocuous-looking keys (e.g. the
        // `latest_reliability_packet` blob, interpolated `route_*`/`runtime_*`/
        // `storage_*` keys that the sensitive-key fragment list does not catch).
        // The off-device contract is positive-allowlist gated like
        // `captureObservabilityEvent`, not just key-drop + redaction, so we
        // filter to the known-safe key set owned by `SupportDiagnosticsBundle`
        // before send. Surviving values still pass through the text redactor
        // inside `captureMessageEvent` as defense-in-depth.
        captureMessageEvent(
            level: .warning,
            title: "support_diagnostic_event",
            message: "Manual support diagnostic event from Transcripted Settings",
            tags: [
                "source": "support_diagnostics",
                "engine": "support",
                "event": "diagnostic_event",
            ],
            extra: SupportDiagnosticsBundle.allowlistedSentryContext(extra),
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
}

/// Top-level handler — `NSSetUncaughtExceptionHandler` takes a `@convention(c)`
/// function pointer, so this must be a free function with no captured context.
/// It attaches the parsed class + selector (kept as crash tags, like sanitized
/// stack-frame symbols) and then forwards to the previously-installed handler.
private func transcriptedUnrecognizedSelectorHandler(_ exception: NSException) {
    if let parsed = UnrecognizedSelectorReason.parse(exception.reason) {
        let tags = SentryPayloadSanitizer.sanitizeTags([
            "unrecognized_selector": parsed.selector,
            "unrecognized_selector_class": parsed.receiver,
        ])
        SentrySDK.configureScope { scope in
            scope.setTags(tags)
        }
    }
    CrashReporter.forwardUncaughtException(exception)
}
