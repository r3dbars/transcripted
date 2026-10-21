import CryptoKit
import Foundation

/// Finds passages from the user's meetings, dictations and writing by meaning, not just matching
/// words, with EmbeddingGemma running locally (llama.cpp's server). The passages and their vectors
/// stay on this Mac: the vectors are cached in Application Support, keyed by each passage's hash,
/// so only new captures are embedded. Owner-only, with the rest of Next Sentence.
final class NextSentenceSemanticIndex: @unchecked Sendable {
    struct Hit: Sendable {
        let chunk: NextSentenceChunker.Chunk
        let score: Float
    }

    /// EmbeddingGemma vectors are trained to be cut short; 256 of 768 keeps search quality and a small cache.
    static let dimensions = 256
    /// Cosine similarity a passage needs to count as related (unrelated text sits near 0.6).
    static let floor: Float = 0.72
    static let documentPrompt = "title: %@ | text: "
    static let queryPrompt = "task: search result | query: "

    private let queue = DispatchQueue(label: "transcripted.next-sentence.semantic", qos: .utility)
    private var files: [String: (modified: Date, chunks: [NextSentenceChunker.Chunk])] = [:]
    private var cache: [String: [Float]] = [:]
    private var cacheLoaded = false
    private var server: Process?

    /// Brings the index up to date in the background, so the first press is quick.
    func refresh() {
        queue.async { self.refreshNow() }
    }

    func stop() {
        queue.async { self.server?.terminate(); self.server = nil }
    }

    /// The passages most related to `text`, best first, leaving out any that are just what's on screen.
    func search(_ text: String, screen: String, limit: Int = 4) async -> [Hit] {
        await withCheckedContinuation { continuation in
            queue.async { continuation.resume(returning: self.searchNow(text, screen: screen, limit: limit)) }
        }
    }

    /// For each person, the passages that mention them by name, the ones most related to `text` first.
    func mentions(of people: [String], relatedTo text: String, perPerson: Int = 3) async -> [(name: String, chunk: NextSentenceChunker.Chunk)] {
        guard !people.isEmpty else { return [] }
        return await withCheckedContinuation { continuation in
            queue.async { continuation.resume(returning: self.mentionsNow(of: people, relatedTo: text, perPerson: perPerson)) }
        }
    }

    private func mentionsNow(of people: [String], relatedTo text: String, perPerson: Int) -> [(name: String, chunk: NextSentenceChunker.Chunk)] {
        refreshNow()
        let query = String(text.suffix(800)).trimmingCharacters(in: .whitespacesAndNewlines)
        let vector = query.isEmpty ? nil : embed([Self.queryPrompt + query])?.first
        let all = files.values.flatMap(\.chunks)
        var found: [(name: String, chunk: NextSentenceChunker.Chunk)] = []
        for name in people {
            guard let pattern = try? NSRegularExpression(pattern: "\\b\(NSRegularExpression.escapedPattern(for: name))\\b") else { continue }
            let mentioning = all.filter { chunk in
                let range = NSRange(chunk.text.startIndex..., in: chunk.text)
                return pattern.firstMatch(in: chunk.text, range: range) != nil
            }
            let ranked = mentioning.map { chunk -> (NextSentenceChunker.Chunk, Float) in
                guard let vector, let candidate = cache[Self.key(chunk)] else { return (chunk, 0) }
                return (chunk, zip(vector, candidate).reduce(Float(0)) { $0 + $1.0 * $1.1 })
            }.sorted { $0.1 != $1.1 ? $0.1 > $1.1 : $0.0.date > $1.0.date }
            found += ranked.prefix(perPerson).map { (name, $0.0) }
        }
        return found
    }

    // MARK: Searching

    private func searchNow(_ text: String, screen: String, limit: Int) -> [Hit] {
        refreshNow()
        let query = String(text.suffix(800)).trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty, let vector = embed([Self.queryPrompt + query])?.first else { return [] }
        let screenKey = NextSentenceChunker.normalized(String(screen.suffix(4_000)))
        var scored: [Hit] = []
        for chunk in files.values.flatMap(\.chunks) {
            guard let candidate = cache[Self.key(chunk)] else { continue }
            let score = zip(vector, candidate).reduce(Float(0)) { $0 + $1.0 * $1.1 }
            if score >= Self.floor { scored.append(Hit(chunk: chunk, score: score)) }
        }
        scored.sort { $0.score > $1.score }
        let best = scored.first?.score ?? 0
        var seen = Set<String>()
        var hits: [Hit] = []
        for hit in scored where hit.score >= best - 0.1 {
            let opening = String(NextSentenceChunker.normalized(hit.chunk.text).prefix(80))
            // Their writing captures include what they're typing right now; that's the screen, not context.
            guard opening.count >= 20, !screenKey.contains(opening), seen.insert(opening).inserted else { continue }
            hits.append(hit)
            if hits.count == limit { break }
        }
        return hits
    }

    // MARK: Indexing

    private func refreshNow() {
        guard ensureServer() else { return }
        if !cacheLoaded { loadCache() }
        let manager = FileManager.default
        var current: [String: (modified: Date, chunks: [NextSentenceChunker.Chunk])] = [:]
        for (kind, directory) in Self.captureDirectories() {
            let names = (try? manager.contentsOfDirectory(atPath: directory.path)) ?? []
            for name in names where name.hasSuffix(".md") {
                let url = directory.appendingPathComponent(name)
                let modified = (try? manager.attributesOfItem(atPath: url.path)[.modificationDate] as? Date) ?? .distantPast
                if let known = files[url.path], known.modified == modified {
                    current[url.path] = known
                } else if let markdown = try? String(contentsOf: url, encoding: .utf8) {
                    current[url.path] = (modified, NextSentenceChunker.chunks(markdown: markdown, kind: kind))
                }
            }
        }
        files = current
        let missing = current.values.flatMap(\.chunks).filter { cache[Self.key($0)] == nil }
        guard !missing.isEmpty else { return }
        var added = 0
        for start in stride(from: 0, to: missing.count, by: 32) {
            let batch = Array(missing[start..<min(start + 32, missing.count)])
            let inputs = batch.map { String(format: Self.documentPrompt, $0.title.isEmpty ? "none" : $0.title) + $0.text }
            guard let vectors = embed(inputs), vectors.count == batch.count else { break }
            for (chunk, vector) in zip(batch, vectors) { cache[Self.key(chunk)] = vector }
            added += batch.count
        }
        if added > 0 { saveCache() }
    }

    static func key(_ chunk: NextSentenceChunker.Chunk) -> String {
        SHA256.hash(data: Data((chunk.title + "\n" + chunk.text).utf8)).prefix(12).map { String(format: "%02x", $0) }.joined()
    }

    /// Where Transcripted saves captures: from its MCP directories file, or the default library.
    static func captureDirectories() -> [(kind: String, url: URL)] {
        let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Transcripted", isDirectory: true)
        let configured = (try? Data(contentsOf: support.appendingPathComponent("mcp-directories.json")))
            .flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: Any] } ?? [:]
        let library = support.appendingPathComponent("captures", isDirectory: true)
        return [("meeting", "meetingsDirectory", "meetings"), ("dictation", "dictationsDirectory", "dictations"),
                ("writing", "writingDirectory", "writing")].map { kind, key, folder in
            let path = configured[key] as? String
            return (kind, path.map { URL(fileURLWithPath: $0, isDirectory: true) } ?? library.appendingPathComponent(folder, isDirectory: true))
        }
    }

    // MARK: The embedding server

    /// Vectors for `inputs`, cut to `dimensions` and normalized. Nil if the server can't answer.
    private func embed(_ inputs: [String]) -> [[Float]]? {
        guard let base = NextSentencePreferences.embeddingURL(),
              let body = try? JSONSerialization.data(withJSONObject: ["input": inputs]) else { return nil }
        var request = URLRequest(url: base.appendingPathComponent("v1/embeddings"), timeoutInterval: 30)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = body
        guard let data = Self.fetch(request),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let rows = object["data"] as? [[String: Any]] else { return nil }
        let ordered = rows.sorted { ($0["index"] as? Int ?? 0) < ($1["index"] as? Int ?? 0) }
        return ordered.compactMap { row in
            guard let raw = row["embedding"] as? [Double] else { return nil }
            let cut = raw.prefix(Self.dimensions).map(Float.init)
            let length = sqrt(cut.reduce(0) { $0 + $1 * $1 })
            return length > 0 ? cut.map { $0 / length } : nil
        }
    }

    private func ensureServer() -> Bool {
        guard let base = NextSentencePreferences.embeddingURL() else { return false }
        let health = URLRequest(url: base.appendingPathComponent("health"), timeoutInterval: 1.5)
        if Self.fetch(health) != nil { return true }
        guard server?.isRunning != true, let launch = NextSentencePreferences.embeddingLaunch() else { return false }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: launch.server)
        process.arguments = ["-m", launch.model, "--embedding", "--host", "127.0.0.1", "--port", "\(base.port ?? 8811)",
                             "-ngl", "0", "-c", "8192", "-b", "2048", "-ub", "2048", "-np", "4", "--no-webui"]
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        do { try process.run() } catch { return false }
        server = process
        for _ in 0..<120 {
            Thread.sleep(forTimeInterval: 0.5)
            if Self.fetch(health) != nil { return true }
            if !process.isRunning { return false }
        }
        return false
    }

    /// A blocking request, for the index's own background queue.
    private static func fetch(_ request: URLRequest) -> Data? {
        let box = NextSentenceDataBox()
        let done = DispatchSemaphore(value: 0)
        URLSession.shared.dataTask(with: request) { data, response, _ in
            if (response as? HTTPURLResponse)?.statusCode == 200 { box.data = data }
            done.signal()
        }.resume()
        done.wait()
        return box.data
    }

    // MARK: The vector cache

    private var cacheURL: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Transcripted/next-sentence/embeddings-\(Self.dimensions).json")
    }

    private func loadCache() {
        cacheLoaded = true
        guard let data = try? Data(contentsOf: cacheURL),
              let stored = try? JSONSerialization.jsonObject(with: data) as? [String: String] else { return }
        for (key, encoded) in stored {
            guard let bytes = Data(base64Encoded: encoded), bytes.count == Self.dimensions * 4 else { continue }
            cache[key] = bytes.withUnsafeBytes { Array($0.bindMemory(to: Float.self)) }
        }
    }

    private func saveCache() {
        var stored: [String: String] = [:]
        for (key, vector) in cache {
            stored[key] = vector.withUnsafeBufferPointer { Data(buffer: $0) }.base64EncodedString()
        }
        guard let data = try? JSONSerialization.data(withJSONObject: stored) else { return }
        try? FileManager.default.createDirectory(at: cacheURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? data.write(to: cacheURL, options: .atomic)
    }
}

/// Carries a response out of URLSession's callback. Written once, before the semaphore is signaled.
final class NextSentenceDataBox: @unchecked Sendable {
    var data: Data?
}
