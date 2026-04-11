// CrashReporter.swift
// Privacy-safe Sentry reporting via raw HTTP — no SDK dependency required.
//
// HOW IT WORKS:
//   1. Reads Sentry DSN/config from Info.plist or process environment.
//   2. Respects the user-facing crash reporting toggle in Settings.
//   3. Scrubs sensitive values before sending crash and non-fatal error events.

import Foundation

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

// MARK: - CrashReporter

final class CrashReporter {
    static let shared = CrashReporter()

    static var isAvailable: Bool {
        SentryRuntimeConfiguration.dsn() != nil
    }

    private init() {}

    private var projectID = ""
    private var publicKey = ""
    private var host = ""
    private var environment = "production"
    private var releaseName = "transcripted@unknown"
    private var dist: String?
    private var isConfigured = false
    private var handlerInstalled = false
    private var userEnabled = CrashReportingPreferences.isEnabled()

    // MARK: - Setup

    /// Call once in applicationDidFinishLaunching.
    static func setup(dsn: String? = SentryRuntimeConfiguration.dsn()) {
        guard let dsn else { return }
        shared.configure(dsn: dsn)
        shared.refreshPreference()
        shared.installUncaughtExceptionHandlerIfNeeded()
    }

    func refreshPreference() {
        userEnabled = CrashReportingPreferences.isEnabled()
    }

    private var isEnabled: Bool {
        isConfigured && userEnabled
    }

    private func configure(dsn: String) {
        guard let url = URL(string: dsn),
              let key = url.user,
              let host = url.host else {
            fputs("[CrashReporter] Invalid DSN — crash reporting disabled\n", stderr)
            isConfigured = false
            return
        }

        publicKey = key
        self.host = host
        projectID = url.path.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        environment = SentryRuntimeConfiguration.environment()
        releaseName = SentryRuntimeConfiguration.releaseName()
        dist = SentryRuntimeConfiguration.dist()
        isConfigured = !projectID.isEmpty && !publicKey.isEmpty
    }

    private func installUncaughtExceptionHandlerIfNeeded() {
        guard isConfigured, !handlerInstalled else { return }

        NSSetUncaughtExceptionHandler { exception in
            let message = exception.reason ?? "Unknown exception"
            let name = exception.name.rawValue
            let symbols = exception.callStackSymbols.prefix(20).joined(separator: "\n")
            CrashReporter.shared.sendEvent(
                level: "fatal",
                title: name,
                message: message,
                tags: ["source": "uncaught_exception"],
                extra: ["callstack": symbols]
            )
            Thread.sleep(forTimeInterval: 1.0)
        }

        handlerInstalled = true
    }

    // MARK: - Manual Capture

    /// Call inside catch blocks to report Swift errors.
    func capture(error: Error, context: String = "") {
        let message = context.isEmpty
            ? error.localizedDescription
            : "\(context): \(error.localizedDescription)"
        sendEvent(
            level: "error",
            title: String(describing: type(of: error)),
            message: message,
            tags: ["source": "swift_error"]
        )
    }

    /// Report a non-fatal message with optional context dict.
    func capture(message: String, level: String = "warning", extra: [String: String] = [:]) {
        sendEvent(
            level: level,
            title: message,
            message: message,
            tags: ["source": "manual_message"],
            extra: extra
        )
    }

    /// Forward structured observability errors into Sentry with a stable grouping key.
    func captureObservabilityEvent(
        level: EventLevel,
        engine: String,
        event: String,
        message: String,
        context: [String: String]
    ) {
        sendEvent(
            level: level.rawValue,
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

    // MARK: - HTTP

    private func sendEvent(
        level: String,
        title: String,
        message: String,
        tags: [String: String] = [:],
        extra: [String: String] = [:],
        fingerprint: [String]? = nil
    ) {
        guard isEnabled else { return }

        let sanitizedTitle = SentryPayloadSanitizer.sanitizeText(title)
        let sanitizedMessage = SentryPayloadSanitizer.sanitizeText(message)
        let sanitizedTags = SentryPayloadSanitizer.sanitizeTags(tags)
        let sanitizedExtra = SentryPayloadSanitizer.sanitizeContext(extra)

        var payload: [String: Any] = [
            "event_id": UUID().uuidString.replacingOccurrences(of: "-", with: ""),
            "timestamp": ISO8601DateFormatter().string(from: Date()),
            "platform": "cocoa",
            "environment": environment,
            "release": releaseName,
            "level": level,
            "logger": "CrashReporter",
            "message": ["formatted": "\(sanitizedTitle): \(sanitizedMessage)"],
            "contexts": [
                "os": [
                    "name": "macOS",
                    "version": ProcessInfo.processInfo.operatingSystemVersionString,
                ],
                "app": [
                    "app_name": "Transcripted",
                    "app_version": Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "unknown",
                ],
            ],
        ]

        if let dist, !dist.isEmpty {
            payload["dist"] = dist
        }

        if !sanitizedTags.isEmpty {
            payload["tags"] = sanitizedTags
        }

        if !sanitizedExtra.isEmpty {
            payload["extra"] = sanitizedExtra
        }

        if let fingerprint, !fingerprint.isEmpty {
            payload["fingerprint"] = fingerprint
        }

        guard let url = URL(string: "https://\(host)/api/\(projectID)/store/"),
              let body = try? JSONSerialization.data(withJSONObject: payload) else { return }

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue(
            "Sentry sentry_version=7,sentry_key=\(publicKey),sentry_client=transcripted/1.0",
            forHTTPHeaderField: "X-Sentry-Auth"
        )
        request.httpBody = body
        request.timeoutInterval = 5

        URLSession.shared.dataTask(with: request).resume()
    }
}
