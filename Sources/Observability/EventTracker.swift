// EventTracker.swift
// Privacy-first usage analytics via TelemetryDeck's HTTP API — no SDK, no dependencies.
//
// TelemetryDeck is built for Apple developers: no IP storage, no PII, server-side
// hashing of the user identifier. Matches the app's local-first privacy positioning.
//
// SETUP:
//   1. Create a free TelemetryDeck account at telemetrydeck.com
//   2. Create an app — copy the App ID (UUID format)
//   3. Paste it into telemetryAppID below
//   4. EventTracker is ready — call sites are already in place
//
// SIGNALS TRACKED:
//   app.launched              TranscriptedAppState.initialize()
//   dictation.completed       After Whisper transcription is pasted
//   draft.shown               When the review overlay appears
//   draft.accepted            After confirmed inject (paste)
//   draft.rejected            After cancelSession()
//   onboarding.completed      After style profile is generated
//   paywall.shown             (future — DraftGate)
//   upgrade.completed         (future — RevenueCat)

import Foundation

// MARK: - Configuration

/// Your TelemetryDeck App ID (UUID format).
/// Get it from telemetrydeck.com → App Settings.
private let telemetryAppID = ""  // ← fill in before shipping

// MARK: - EventTracker

final class EventTracker {

    // MARK: - Public API

    /// Track a signal. Call from any thread — always fires async.
    static func track(_ signal: String, with payload: [String: String] = [:]) {
        guard !telemetryAppID.isEmpty else { return }
        Task.detached(priority: .utility) {
            shared.send(signal: signal, payload: payload)
        }
    }

    // MARK: - Private

    private static let shared = EventTracker()
    private init() {}

    /// Anonymous user identifier — random UUID, stored across launches,
    /// never tied to name/email/IP. TelemetryDeck hashes it server-side.
    private let userID: String = {
        let key = "draft.analytics.userID"
        if let existing = UserDefaults.standard.string(forKey: key) { return existing }
        let new = UUID().uuidString
        UserDefaults.standard.set(new, forKey: key)
        return new
    }()

    private let session: URLSession = {
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = 5
        return URLSession(configuration: config)
    }()

    private func send(signal: String, payload: [String: String]) {
        guard let url = URL(string: "https://nom.telemetrydeck.com/v2/") else { return }

        let body: [String: Any] = [
            "appID": telemetryAppID,
            "clientUser": userID,
            "sessionID": sessionID,
            "type": signal,
            "payload": enriched(payload)
        ]
        // TelemetryDeck v2 expects an array of signals
        let envelope = [body]

        guard let data = try? JSONSerialization.data(withJSONObject: envelope) else { return }

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = data

        session.dataTask(with: request).resume()
    }

    /// Stable per-launch session identifier
    private let sessionID = UUID().uuidString

    /// Merge caller payload with automatic device context.
    private func enriched(_ payload: [String: String]) -> [String: String] {
        var result = payload
        result["os_version"] = ProcessInfo.processInfo.operatingSystemVersionString
        result["app_version"] = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "unknown"
        return result
    }
}
