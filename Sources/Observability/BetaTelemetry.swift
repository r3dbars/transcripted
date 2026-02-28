// BetaTelemetry.swift
// Fire-and-forget session events + log shipping for beta builds.
// Events go to POST /events, logs go to POST /logs on the proxy.

#if BETA_BUILD

import Foundation

@MainActor
final class BetaTelemetry {
    static let shared = BetaTelemetry()
    private init() {}

    /// Send a session event after each draft (fire-and-forget)
    func sendEvent(type: String, sourceApp: String? = nil, payload: [String: Any] = [:]) {
        guard let auth = AuthCredential.load() else { return }
        let url = URL(string: "\(BetaConfig.proxyBaseURL)/events")!

        Task.detached(priority: .utility) {
            var request = URLRequest(url: url)
            request.httpMethod = "POST"
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            auth.apply(to: &request)

            var body: [String: Any] = [
                "event_type": type,
            ]
            if let app = sourceApp { body["source_app"] = app }
            if !payload.isEmpty { body["payload"] = payload }

            request.httpBody = try? JSONSerialization.data(withJSONObject: body)
            _ = try? await URLSession.shared.data(for: request)
        }
    }

    /// Ship recent debug log lines — called on app quit (synchronous, 3s timeout)
    func shipLogs() {
        guard let auth = AuthCredential.load() else { return }
        let logURL = URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent("draft-debug.log")
        guard let data = try? String(contentsOf: logURL, encoding: .utf8) else { return }
        let lines = data.components(separatedBy: "\n").suffix(100).joined(separator: "\n")

        var request = URLRequest(url: URL(string: "\(BetaConfig.proxyBaseURL)/logs")!)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        auth.apply(to: &request)
        request.httpBody = try? JSONSerialization.data(withJSONObject: ["log_lines": lines])

        // Synchronous wait — applicationWillTerminate can't use async
        let semaphore = DispatchSemaphore(value: 0)
        URLSession.shared.dataTask(with: request) { _, _, _ in semaphore.signal() }.resume()
        _ = semaphore.wait(timeout: .now() + 3)
    }
}

#endif
