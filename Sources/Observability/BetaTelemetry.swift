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

    // Byte offsets — only ship content written since last successful upload
    private var debugLogOffset: UInt64 = 0
    private var eventsOffset: UInt64 = 0
    private var shippingTimer: Task<Void, Never>?

    private static let shippingIntervalSeconds: UInt64 = 60
    private static let maxChunkBytes: Int = 64 * 1024  // 64KB per file per cycle

    private var debugLogURL: URL {
        URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent("draft-debug.log")
    }

    private var eventsURL: URL {
        FileManager.default.draftAppSupportDir.appendingPathComponent("events.jsonl")
    }

    // MARK: - Discrete events (fire-and-forget, unchanged)

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
        guard let auth = AuthCredential.load() else { return }

        // Ship any remaining debug log content
        let logChunk = readChunk(from: debugLogURL, offset: &debugLogOffset)
        let eventChunk = readChunk(from: eventsURL, offset: &eventsOffset)

        guard logChunk != nil || eventChunk != nil else { return }

        var body: [String: Any] = [:]
        if let log = logChunk { body["log_lines"] = log }
        if let events = eventChunk { body["event_lines"] = events }

        var request = URLRequest(url: URL(string: "\(BetaConfig.proxyBaseURL)/logs")!)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        auth.apply(to: &request)
        request.httpBody = try? JSONSerialization.data(withJSONObject: body)

        // Synchronous wait — applicationWillTerminate can't use async
        let semaphore = DispatchSemaphore(value: 0)
        URLSession.shared.dataTask(with: request) { _, _, _ in semaphore.signal() }.resume()
        _ = semaphore.wait(timeout: .now() + 3)
    }

    // MARK: - Incremental shipping

    private func shipIncremental() async {
        guard let auth = AuthCredential.load() else { return }

        // Read new chunks from both files
        var tempDebugOffset = debugLogOffset
        var tempEventsOffset = eventsOffset
        let logChunk = readChunk(from: debugLogURL, offset: &tempDebugOffset)
        let eventChunk = readChunk(from: eventsURL, offset: &tempEventsOffset)

        guard logChunk != nil || eventChunk != nil else { return }

        var body: [String: Any] = [:]
        if let log = logChunk { body["log_lines"] = log }
        if let events = eventChunk { body["event_lines"] = events }

        var request = URLRequest(url: URL(string: "\(BetaConfig.proxyBaseURL)/logs")!)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        auth.apply(to: &request)
        request.httpBody = try? JSONSerialization.data(withJSONObject: body)

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
