// BetaTelemetry.swift
// Fire-and-forget session events + periodic incremental log/event shipping for beta builds.
// Events go to POST /events, logs+events go to POST /logs on the proxy.
// Periodic shipping runs every 60s, sending only new bytes since last successful upload.

#if BETA_BUILD

import Foundation

@MainActor
final class BetaTelemetry {
    static let shared = BetaTelemetry()
    private init() {}
    private static let tokenPlaceholder = "BETA_TOKEN_PLACEHOLDER"

    // Byte offsets — only ship content written since last successful upload
    private var debugLogOffset: UInt64 = 0
    private var eventsOffset: UInt64 = 0
    private var shippingTimer: Task<Void, Never>?

    private static let shippingIntervalSeconds: UInt64 = 60
    private static let maxChunkBytes: Int = 64 * 1024  // 64KB per file per cycle

    private var debugLogURL: URL {
        FileManager.default.transcriptedLogsDir.appendingPathComponent("debug.log")
    }

    private var eventsURL: URL {
        FileManager.default.transcriptedLogsDir.appendingPathComponent("events.jsonl")
    }

    // MARK: - Discrete events (fire-and-forget, unchanged)

    func sendEvent(type: String, sourceApp: String? = nil, payload: [String: Any] = [:]) {
        guard let token = Self.activeToken() else { return }

        Task.detached(priority: .utility) {
            var body: [String: Any] = [
                "event_type": type,
            ]
            if let app = sourceApp { body["source_app"] = app }
            if !payload.isEmpty { body["payload"] = payload }

            guard let request = Self.makeJSONRequest(
                path: "events",
                token: token,
                body: body,
                failureLabel: "event body"
            ) else {
                return
            }
            _ = try? await URLSession.shared.data(for: request)
        }
    }

    // MARK: - Periodic shipping (60s timer)

    func startPeriodicShipping() {
        shippingTimer?.cancel()
        shippingTimer = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: Self.shippingIntervalSeconds * 1_000_000_000)
                guard !Task.isCancelled else { break }
                await self?.shipIncremental()
            }
        }
    }

    func stopPeriodicShipping() {
        shippingTimer?.cancel()
        shippingTimer = nil
    }

    // MARK: - Quit shipping (synchronous, 3s timeout — called from applicationWillTerminate)

    func shipLogs() {
        guard let token = Self.activeToken(),
              let body = shippingBody(
                logChunk: readChunk(from: debugLogURL, offset: &debugLogOffset),
                eventChunk: readChunk(from: eventsURL, offset: &eventsOffset)
              ),
              let request = Self.makeJSONRequest(
                path: "logs",
                token: token,
                body: body,
                failureLabel: "quit-time log body"
              ) else { return }

        // Synchronous wait — applicationWillTerminate can't use async
        let semaphore = DispatchSemaphore(value: 0)
        URLSession.shared.dataTask(with: request) { _, _, _ in semaphore.signal() }.resume()
        _ = semaphore.wait(timeout: .now() + 3)
    }

    // MARK: - Incremental shipping

    private func shipIncremental() async {
        guard let token = Self.activeToken() else { return }

        // Read new chunks from both files
        var tempDebugOffset = debugLogOffset
        var tempEventsOffset = eventsOffset
        let logChunk = readChunk(from: debugLogURL, offset: &tempDebugOffset)
        let eventChunk = readChunk(from: eventsURL, offset: &tempEventsOffset)

        guard let body = shippingBody(logChunk: logChunk, eventChunk: eventChunk),
              let request = Self.makeJSONRequest(
                path: "logs",
                token: token,
                body: body,
                failureLabel: "incremental log body"
              ) else { return }

        do {
            let (_, response) = try await URLSession.shared.data(for: request)
            if let http = response as? HTTPURLResponse, http.statusCode == 200 {
                // Advance offsets only on success
                debugLogOffset = tempDebugOffset
                eventsOffset = tempEventsOffset
            }
        } catch {
            // Leave offsets unchanged — will retry next cycle
        }
    }

    private static func activeToken() -> String? {
        let token = BetaConfig.userToken
        return token == tokenPlaceholder ? nil : token
    }

    private static func makeJSONRequest(
        path: String,
        token: String,
        body: [String: Any],
        failureLabel: String
    ) -> URLRequest? {
        guard let url = URL(string: "\(BetaConfig.proxyBaseURL)/\(path)") else {
            fputs("⚠️ TELEMETRY | invalid \(path) URL\n", stderr)
            return nil
        }

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")

        do {
            request.httpBody = try JSONSerialization.data(withJSONObject: body)
            return request
        } catch {
            fputs("⚠️ TELEMETRY | failed to serialize \(failureLabel): \(error.localizedDescription)\n", stderr)
            return nil
        }
    }

    private func shippingBody(logChunk: String?, eventChunk: String?) -> [String: Any]? {
        var body: [String: Any] = [:]
        if let logChunk {
            body["log_lines"] = redactChunk(logChunk)
        }
        if let eventChunk {
            body["event_lines"] = redactChunk(eventChunk)
        }
        return body.isEmpty ? nil : body
    }

    // MARK: - Log Redaction

    // Pre-compiled regexes — avoids recompilation per log line
    private static let userPathRegex = try! NSRegularExpression(pattern: #"/Users/[^/]+/"#)
    private static let apiKeyRegex = try! NSRegularExpression(pattern: #"sk-ant-[A-Za-z0-9_-]+"#)
    private static let bearerRegex = try! NSRegularExpression(pattern: #"Bearer [A-Za-z0-9._-]+"#)
    private static let sourceAppNameJSONRegex = try! NSRegularExpression(pattern: #""source_app_name"\s*:\s*"[^"]*""#)
    private static let sourceAppBundleJSONRegex = try! NSRegularExpression(pattern: #""source_app_bundle_id"\s*:\s*"[^"]*""#)
    private static let transcriptURLJSONRegex = try! NSRegularExpression(pattern: #""transcript_url"\s*:\s*"[^"]*""#)
    private static let titleJSONRegex = try! NSRegularExpression(pattern: #""title"\s*:\s*"[^"]*""#)

    /// Redact all sensitive data in a multi-line log chunk.
    /// Applies regexes directly on the full chunk (avoids per-line split/rejoin).
    private func redactChunk(_ chunk: String) -> String {
        var result = chunk
        var range = NSRange(result.startIndex..., in: result)
        result = Self.userPathRegex.stringByReplacingMatches(in: result, range: range, withTemplate: "/Users/****/")
        range = NSRange(result.startIndex..., in: result)
        result = Self.apiKeyRegex.stringByReplacingMatches(in: result, range: range, withTemplate: "sk-ant-****")
        range = NSRange(result.startIndex..., in: result)
        result = Self.bearerRegex.stringByReplacingMatches(in: result, range: range, withTemplate: "Bearer ****")
        range = NSRange(result.startIndex..., in: result)
        result = Self.sourceAppNameJSONRegex.stringByReplacingMatches(in: result, range: range, withTemplate: "\"source_app_name\":\"[redacted]\"")
        range = NSRange(result.startIndex..., in: result)
        result = Self.sourceAppBundleJSONRegex.stringByReplacingMatches(in: result, range: range, withTemplate: "\"source_app_bundle_id\":\"[redacted]\"")
        range = NSRange(result.startIndex..., in: result)
        result = Self.transcriptURLJSONRegex.stringByReplacingMatches(in: result, range: range, withTemplate: "\"transcript_url\":\"[redacted]\"")
        range = NSRange(result.startIndex..., in: result)
        result = Self.titleJSONRegex.stringByReplacingMatches(in: result, range: range, withTemplate: "\"title\":\"[redacted]\"")
        return result
    }

    // MARK: - File chunk reading

    /// Read up to maxChunkBytes from the file starting at offset.
    /// Advances the offset in-place. Returns nil if no new content.
    private func readChunk(from url: URL, offset: inout UInt64) -> String? {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return nil }
        defer { try? handle.close() }

        let fileSize = handle.seekToEndOfFile()
        guard fileSize > offset else {
            // File was truncated (e.g., log rotation) — reset to start
            if fileSize < offset { offset = 0 }
            return nil
        }

        handle.seek(toFileOffset: offset)
        let bytesToRead = min(UInt64(Self.maxChunkBytes), fileSize - offset)
        let data = handle.readData(ofLength: Int(bytesToRead))
        guard !data.isEmpty, let text = String(data: data, encoding: .utf8) else { return nil }

        offset += UInt64(data.count)
        return text
    }
}

#endif
