// CrashReporter.swift
// Lightweight Sentry crash reporting via raw HTTP — no SDK, no dependencies.
//
// HOW IT WORKS:
//   1. NSSetUncaughtExceptionHandler catches ObjC/SwiftUI runtime exceptions.
//   2. call CrashReporter.shared.capture(error:) anywhere you catch a Swift error.
//   3. Events POST to Sentry's Store API asynchronously (fire-and-forget).
//
// SETUP:
//   1. Create a Sentry project at sentry.io (free tier, Cocoa platform)
//   2. Copy the DSN from Project Settings → Client Keys
//   3. Replace the placeholder below with your real DSN
//   4. Call CrashReporter.setup() in applicationDidFinishLaunching

import Foundation

// MARK: - Configuration

/// Paste your Sentry DSN here. Format: https://KEY@HOST/PROJECT_ID
/// Leave empty to disable crash reporting (development builds).
private let sentryDSN = ""   // ← fill in before shipping

// MARK: - CrashReporter

final class CrashReporter {
    static let shared = CrashReporter()
    private init() {}

    private var projectID: String = ""
    private var publicKey: String = ""
    private var host: String = ""
    private var isEnabled = false

    // MARK: - Setup

    /// Call once in applicationDidFinishLaunching.
    static func setup(dsn: String = sentryDSN) {
        guard !dsn.isEmpty else { return }
        shared.configure(dsn: dsn)
        shared.installUncaughtExceptionHandler()
    }

    private func configure(dsn: String) {
        // Parse: https://KEY@HOST/PROJECT_ID
        guard let url = URL(string: dsn),
              let key = url.user,
              let host = url.host else {
            print("[CrashReporter] Invalid DSN — crash reporting disabled")
            return
        }
        self.publicKey = key
        self.host = host
        self.projectID = url.path.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        self.isEnabled = !projectID.isEmpty && !publicKey.isEmpty
    }

    private func installUncaughtExceptionHandler() {
        NSSetUncaughtExceptionHandler { exception in
            let message = exception.reason ?? "Unknown exception"
            let name = exception.name.rawValue
            let symbols = exception.callStackSymbols.prefix(20).joined(separator: "\n")
            CrashReporter.shared.sendEvent(
                level: "fatal",
                title: name,
                message: message,
                extra: ["callstack": symbols]
            )
            // Brief sleep so the async POST can fire before process dies
            Thread.sleep(forTimeInterval: 1.0)
        }
    }

    // MARK: - Manual Capture

    /// Call inside catch blocks to report Swift errors.
    func capture(error: Error, context: String = "") {
        let message = context.isEmpty ? error.localizedDescription
                                      : "\(context): \(error.localizedDescription)"
        sendEvent(level: "error", title: String(describing: type(of: error)), message: message)
    }

    /// Report a non-fatal message with optional context dict.
    func capture(message: String, level: String = "warning", extra: [String: String] = [:]) {
        sendEvent(level: level, title: message, message: message, extra: extra)
    }

    // MARK: - HTTP

    private func sendEvent(
        level: String,
        title: String,
        message: String,
        extra: [String: String] = [:]
    ) {
        guard isEnabled else { return }

        var payload: [String: Any] = [
            "event_id": UUID().uuidString.replacingOccurrences(of: "-", with: ""),
            "timestamp": ISO8601DateFormatter().string(from: Date()),
            "platform": "cocoa",
            "level": level,
            "logger": "CrashReporter",
            "message": ["formatted": "\(title): \(message)"],
            "contexts": [
                "os": [
                    "name": "macOS",
                    "version": ProcessInfo.processInfo.operatingSystemVersionString
                ],
                "app": [
                    "app_name": "Transcripted",
                    "app_version": Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "unknown"
                ]
            ]
        ]

        if !extra.isEmpty {
            payload["extra"] = extra
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
