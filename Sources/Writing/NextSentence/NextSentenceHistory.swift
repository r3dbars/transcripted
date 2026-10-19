import Foundation

/// Searches the user's saved meetings, dictations and writing through the bundled
/// `transcripted-mcp` helper (the app has no in-process index). Kept running between presses.
/// Everything stays on this Mac; results are memory-only.
final class NextSentenceHistory: @unchecked Sendable {
    private let queue = DispatchQueue(label: "transcripted.next-sentence.history")
    private var helper: NextSentenceLineProcess?
    private var nextID = 1

    /// Warm the helper so the first press doesn't pay its start-up.
    func prewarm() {
        queue.async { _ = try? self.ensureStarted() }
    }

    func stop() {
        queue.async { self.helper?.terminate(); self.helper = nil }
    }

    /// Up to `limit` sources for the words on screen, best first, plus a few of the user's own
    /// dictated lines to show their voice.
    func lookUp(screen: String, limit: Int = 6) async -> (sources: [NextSentencePrompt.Source], voice: [String]) {
        await withCheckedContinuation { continuation in
            queue.async {
                var hits: [String: (item: [String: Any], score: Int)] = [:]
                for term in NextSentencePrompt.searchTerms(in: screen) {
                    for item in self.search(term, count: 4) {
                        let key = (item["entry_id"] as? String) ?? "\(item["filename"] ?? "")|\(item["datetime"] ?? "")"
                        hits[key, default: (item, 0)].score += 1
                    }
                }
                let ranked = hits.values.sorted {
                    $0.score != $1.score ? $0.score > $1.score : ($0.item["datetime"] as? String ?? "") > ($1.item["datetime"] as? String ?? "")
                }
                let sources = ranked.prefix(limit).enumerated().map { index, hit in Self.source(hit.item, id: "S\(index + 1)") }
                let voice = ranked.filter { $0.item["kind"] as? String == "dictation" }
                    .compactMap { Self.snippets($0.item).first }
                    .filter { $0.count > 30 }
                    .prefix(4)
                continuation.resume(returning: (Array(sources), Array(voice)))
            }
        }
    }

    // MARK: MCP over stdio (on `queue`)

    private func ensureStarted() throws -> NextSentenceLineProcess {
        if let helper, helper.isRunning { return helper }
        let binary = ClaudeDesktopIntegrationInstaller.installedMCPBinaryURL
        guard FileManager.default.isExecutableFile(atPath: binary.path) else {
            throw CocoaError(.fileNoSuchFile)
        }
        let helper = NextSentenceLineProcess(executable: binary, arguments: [],
                                             environment: ["TRANSCRIPTED_DISABLE_FILE_LOGGER": "1"], label: "mcp")
        try helper.start()
        self.helper = helper
        _ = try call(helper, method: "initialize", params: [
            "protocolVersion": "2025-06-18", "capabilities": [:],
            "clientInfo": ["name": "transcripted-next-sentence", "version": "1"],
        ])
        try helper.send(["jsonrpc": "2.0", "method": "notifications/initialized"])
        return helper
    }

    private func search(_ query: String, count: Int) -> [[String: Any]] {
        guard let helper = try? ensureStarted(),
              let result = try? call(helper, method: "tools/call",
                                     params: ["name": "search_context", "arguments": ["query": query, "count": count]]),
              let content = result["content"] as? [[String: Any]],
              let text = content.first?["text"] as? String,
              let json = try? JSONSerialization.jsonObject(with: Data(text.utf8)) as? [String: Any] else { return [] }
        return json["results"] as? [[String: Any]] ?? []
    }

    /// One request, waiting up to two seconds for its answer.
    private func call(_ helper: NextSentenceLineProcess, method: String, params: [String: Any]) throws -> [String: Any] {
        let id = nextID
        nextID += 1
        let done = DispatchSemaphore(value: 0)
        var answer: [String: Any]?
        helper.onLine { line in
            guard (line["id"] as? Int) == id else { return }
            answer = line["result"] as? [String: Any] ?? [:]
            done.signal()
        }
        try helper.send(["jsonrpc": "2.0", "id": id, "method": method, "params": params])
        guard done.wait(timeout: .now() + 2) == .success, let answer else {
            helper.onLine(nil)
            throw CocoaError(.fileReadUnknown)
        }
        helper.onLine(nil)
        return answer
    }

    // MARK: Shaping results

    private static func snippets(_ item: [String: Any]) -> [String] {
        (item["snippets"] as? [[String: Any]] ?? []).compactMap { snippet in
            guard let text = (snippet["text"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines), !text.isEmpty else { return nil }
            if let speaker = snippet["speaker"] as? String { return "\(speaker): \(text)" }
            return text
        }
    }

    private static func source(_ item: [String: Any], id: String) -> NextSentencePrompt.Source {
        NextSentencePrompt.Source(
            id: id,
            kind: item["kind"] as? String ?? "context",
            date: item["date"] as? String ?? "",
            title: String(((item["title"] as? String) ?? (item["filename"] as? String) ?? "").prefix(60)),
            quote: String(snippets(item).prefix(3).joined(separator: " … ").prefix(400))
        )
    }
}
