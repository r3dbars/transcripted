import Foundation

/// Writes with Claude through the `claude` CLI the user is signed into (their own subscription).
/// Owner-only: this sends the prompt, the window screenshot and context snippets to Anthropic.
///
/// The CLI takes ~5s to start, so one process per kind of request is started ahead of time and
/// waits on stdin. Each answers one prompt (fresh context every time), then a new one starts.
final class NextSentenceClaude: @unchecked Sendable {
    enum Failure: LocalizedError {
        case noCLI
        case notSignedIn(String)
        case failed(String)

        var errorDescription: String? {
            switch self {
            case .noCLI: return "Couldn't find the claude command. Set NextSentenceClaudePath to its full path."
            case .notSignedIn: return "Claude isn't signed in. Run `claude auth login` in Terminal, then try again."
            case .failed(let message): return message
            }
        }
    }

    /// Each kind keeps its own warm process, because each is started with its own output format.
    enum Kind: CaseIterable, Sendable {
        case stream, variations, alternatives, swaps

        var schema: [String: Any]? {
            switch self {
            case .stream: return nil
            case .variations: return NextSentencePrompt.variationsSchema
            case .alternatives: return NextSentencePrompt.alternativesSchema
            case .swaps: return NextSentencePrompt.swapsSchema
            }
        }
    }

    static let effort = "low"

    /// The streamed reply (and rewrites of it) is what they read first, so it gets the reply model;
    /// everything else runs in the background on the lighter one. See NextSentencePreferences.
    static func model(for kind: Kind) -> String {
        kind == .stream ? NextSentencePreferences.replyModel() : NextSentencePreferences.backgroundModel()
    }

    private let lock = NSLock()
    private var warm: [Kind: NextSentenceLineProcess] = [:]
    private let schemaJSON: [Kind: String]

    init() {
        var json: [Kind: String] = [:]
        for kind in Kind.allCases {
            guard let schema = kind.schema,
                  let data = try? JSONSerialization.data(withJSONObject: schema, options: [.sortedKeys]) else { continue }
            json[kind] = String(decoding: data, as: UTF8.self)
        }
        schemaJSON = json
    }

    static func binary(userDefaults: UserDefaults = .standard) -> URL? {
        if let override = NextSentencePreferences.claudePathOverride(userDefaults: userDefaults) { return URL(fileURLWithPath: override) }
        if let known = AgentMCPConnector.claudeCodeBinary() { return known }
        let home = FileManager.default.homeDirectoryForCurrentUser
        return [home.appendingPathComponent(".local/node/bin/claude")]
            .first { FileManager.default.isExecutableFile(atPath: $0.path) }
    }

    func prewarm() {
        for kind in Kind.allCases {
            lock.lock()
            let missing = warm[kind] == nil
            lock.unlock()
            guard missing, let process = spawn(kind) else { continue }
            lock.lock()
            if warm[kind] == nil { warm[kind] = process } else { process.terminate() }
            lock.unlock()
        }
    }

    func stop() {
        lock.lock(); defer { lock.unlock() }
        warm.values.forEach { $0.terminate() }
        warm.removeAll()
    }

    /// One reply, word by word. `onText` and `completion` run on a background queue.
    func stream(prompt: String, image: Data?, onText: @escaping (String) -> Void,
                completion: @escaping (Result<String, Error>) -> Void) {
        guard let process = take(.stream) else { return completion(.failure(Failure.noCLI)) }
        var text = ""
        let once = NextSentenceOnce()
        let finish: (Result<String, Error>) -> Void = { result in
            guard once.claim() else { return }
            process.onLine(nil)
            process.terminate()
            completion(result)
        }
        process.onLine { line in
            switch line["type"] as? String {
            case "stream_event":
                let event = line["event"] as? [String: Any] ?? [:]
                if event["type"] as? String == "content_block_delta",
                   let delta = event["delta"] as? [String: Any], delta["type"] as? String == "text_delta",
                   let piece = delta["text"] as? String, !piece.isEmpty {
                    text += piece
                    onText(piece)
                }
                // The CLI spends ~3s on a post-turn summary before its result line; the text is done here.
                if event["type"] as? String == "message_stop", !text.isEmpty { finish(.success(text)) }
            case "result":
                if line["is_error"] as? Bool == true { finish(.failure(Self.failure(line, process))) } else { finish(.success(text)) }
            default: break
            }
        }
        send(prompt: prompt, image: image, to: process, timeout: 60, onTimeout: { finish(.failure(Failure.failed("Claude took too long."))) })
    }

    /// A JSON answer matching `kind`'s schema. `completion` runs on a background queue.
    func structured(_ kind: Kind, prompt: String, image: Data?, timeout: TimeInterval = 90,
                    completion: @escaping (Result<[String: Any], Error>) -> Void) {
        guard kind != .stream, let process = take(kind) else { return completion(.failure(Failure.noCLI)) }
        let once = NextSentenceOnce()
        let finish: (Result<[String: Any], Error>) -> Void = { result in
            guard once.claim() else { return }
            process.onLine(nil)
            process.terminate()
            completion(result)
        }
        process.onLine { line in
            // Structured output arrives as a StructuredOutput tool call, then a result line.
            if line["type"] as? String == "assistant",
               let content = (line["message"] as? [String: Any])?["content"] as? [[String: Any]],
               let call = content.first(where: { $0["type"] as? String == "tool_use" && $0["name"] as? String == "StructuredOutput" }),
               let input = call["input"] as? [String: Any] {
                return finish(.success(input))
            }
            if line["type"] as? String == "result" {
                if line["is_error"] as? Bool == true { return finish(.failure(Self.failure(line, process))) }
                if let structured = line["structured_output"] as? [String: Any] { return finish(.success(structured)) }
                finish(.failure(Failure.failed("Claude didn't return an answer.")))
            }
        }
        send(prompt: prompt, image: image, to: process, timeout: timeout, onTimeout: { finish(.failure(Failure.failed("Claude took too long."))) })
    }

    // MARK: Processes

    private func take(_ kind: Kind) -> NextSentenceLineProcess? {
        lock.lock()
        var process = warm.removeValue(forKey: kind)
        lock.unlock()
        if process == nil || process?.isRunning == false { process = spawn(kind) }
        // Start the next one now, so it's ready by the next press.
        DispatchQueue.global(qos: .utility).async { [weak self] in
            guard let self, let next = self.spawn(kind) else { return }
            self.lock.lock()
            self.warm[kind]?.terminate()
            self.warm[kind] = next
            self.lock.unlock()
        }
        return process
    }

    private func spawn(_ kind: Kind) -> NextSentenceLineProcess? {
        guard let binary = Self.binary() else { return nil }
        var arguments = ["-p", "--model", Self.model(for: kind), "--effort", Self.effort,
                         "--no-session-persistence", "--tools", "", "--strict-mcp-config", "--setting-sources", "",
                         "--input-format", "stream-json", "--output-format", "stream-json", "--verbose"]
        if let schema = schemaJSON[kind] { arguments += ["--json-schema", schema] } else { arguments += ["--include-partial-messages"] }
        let scratch = FileManager.default.temporaryDirectory.appendingPathComponent("transcripted-next-sentence", isDirectory: true)
        try? FileManager.default.createDirectory(at: scratch, withIntermediateDirectories: true)
        let process = NextSentenceLineProcess(
            executable: binary, arguments: arguments,
            environment: ["PATH": "\(binary.deletingLastPathComponent().path):/usr/bin:/bin:" + (ProcessInfo.processInfo.environment["PATH"] ?? "")],
            workingDirectory: scratch,
            label: "claude-\(kind)"
        )
        do { try process.start() } catch { return nil }
        return process
    }

    private func send(prompt: String, image: Data?, to process: NextSentenceLineProcess, timeout: TimeInterval, onTimeout: @escaping () -> Void) {
        var content: [[String: Any]] = []
        if let image {
            content.append(["type": "image", "source": ["type": "base64", "media_type": "image/jpeg", "data": image.base64EncodedString()]])
        }
        content.append(["type": "text", "text": prompt])
        do {
            try process.send(["type": "user", "message": ["role": "user", "content": content]])
        } catch {
            return onTimeout()
        }
        let timeoutBox = NextSentenceCallbackBox(onTimeout)
        DispatchQueue.global().asyncAfter(deadline: .now() + timeout) { timeoutBox.call() }
    }

    private static func failure(_ line: [String: Any], _ process: NextSentenceLineProcess) -> Failure {
        let message = (line["result"] as? String) ?? process.stderrTail()
        if message.range(of: "auth|log ?in|OAuth", options: [.regularExpression, .caseInsensitive]) != nil {
            return .notSignedIn(message)
        }
        return .failed(String(message.prefix(300)))
    }
}

/// Carries a callback across queues. Safe because every callback here is guarded by `NextSentenceOnce`.
final class NextSentenceCallbackBox: @unchecked Sendable {
    private let callback: () -> Void
    init(_ callback: @escaping () -> Void) { self.callback = callback }
    func call() { callback() }
}

/// True for exactly one caller, whichever thread gets there first (an answer or a timeout).
final class NextSentenceOnce: @unchecked Sendable {
    private let lock = NSLock()
    private var done = false

    func claim() -> Bool {
        lock.lock(); defer { lock.unlock() }
        if done { return false }
        done = true
        return true
    }
}
