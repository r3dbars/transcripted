// OrchestratorBridge.swift
// Manages the orchestrator Python subprocess and SSE communication.
//
// Spawns `python3 -m agent.main` on start(), subscribes to SSE stream,
// handles Apply/Skip POST callbacks, and terminates process on stop().

import Foundation
import SwiftUI

private actor AgentLogWriter {
    private var path: String?
    private var handle: FileHandle?

    func reset(at path: String) {
        self.path = path
        closeHandle()
        FileManager.default.createFile(atPath: path, contents: nil)
        openHandleIfNeeded()
    }

    func append(_ line: String) {
        guard !line.isEmpty else { return }
        openHandleIfNeeded()
        guard let data = line.data(using: .utf8), let handle else { return }
        handle.write(data)
    }

    private func openHandleIfNeeded() {
        guard handle == nil, let path else { return }
        handle = FileHandle(forWritingAtPath: path)
        handle?.seekToEndOfFile()
    }

    private func closeHandle() {
        try? handle?.close()
        handle = nil
    }

    deinit {
        try? handle?.close()
    }
}

extension Notification.Name {
    static let promptsDidChange = Notification.Name("promptsDidChange")
}

@MainActor
class OrchestratorBridge: ObservableObject {
    @Published var insights: [InsightCard] = []
    @Published var isConnected = false
    @Published var isAnalyzing = false
    @Published var agentStatus: String = "Starting..."
    @Published var chatMessages: [ChatMessage] = []
    @Published var isChatResponding = false

    var logger: AppLogger?

    private var process: Process?
    private var sseTask: Task<Void, Never>?
    private let port = 19832
    private let agentLogWriter = AgentLogWriter()

    private var baseURL: URL { URL(string: "http://127.0.0.1:\(port)")! }

    /// Agent log file path for Python subprocess output
    private let agentLogPath: String = {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        return home + "/draft-agent.log"
    }()

    // MARK: - Process Lifecycle

    func start() {
        guard process == nil else { return }

        agentStatus = "Starting..."

        // Capture values needed by the background task
        let logPath = agentLogPath
        let execPath = Bundle.main.executablePath ?? "(nil)"
        let logWriter = agentLogWriter

        // Move ALL blocking work (FileManager, Process setup, Process.run())
        // off the main thread. Process.run() can block for code-signing
        // validation, and FileManager I/O adds unnecessary main-thread stalls.
        Task.detached { [weak self, logWriter] in
            await logWriter.reset(at: logPath)

            let proc = Process()

            // Working directory: Draft repo root (agent/ is a sibling of Sources/)
            let execURL = URL(fileURLWithPath: execPath)
            let repoRoot = execURL
                .deletingLastPathComponent()  // Draft (executable) → MacOS/
                .deletingLastPathComponent()  // MacOS/ → Contents/
                .deletingLastPathComponent()  // Contents/ → Draft.app/
                .deletingLastPathComponent()  // Draft.app/ → build/
                .deletingLastPathComponent()  // build/ → Draft/ (repo root)
            proc.currentDirectoryURL = repoRoot

            // Use venv Python if available, fall back to system python3
            let venvPython = repoRoot.appendingPathComponent("agent/.venv/bin/python3")
            let venvExists = FileManager.default.fileExists(atPath: venvPython.path)

            if venvExists {
                proc.executableURL = venvPython
                proc.arguments = ["-m", "agent.main"]
            } else {
                proc.executableURL = URL(fileURLWithPath: "/usr/bin/env")
                proc.arguments = ["python3", "-m", "agent.main"]
            }

            // Clean environment — remove CLAUDECODE to prevent Claude Agent SDK
            // from refusing to run when Draft is launched from a Claude Code session.
            var env = ProcessInfo.processInfo.environment
            env.removeValue(forKey: "CLAUDECODE")
            env.removeValue(forKey: "CLAUDE_CODE_SESSION")
            env["PYTHONUNBUFFERED"] = "1"
            proc.environment = env

            // Pipe stderr/stdout for logging
            let errPipe = Pipe()
            proc.standardError = errPipe
            let outPipe = Pipe()
            proc.standardOutput = outPipe

            proc.terminationHandler = { [weak self] proc in
                Task { @MainActor in
                    let status = proc.terminationStatus
                    self?.isConnected = false
                    self?.agentStatus = status == 0
                        ? "Agent stopped"
                        : "Agent crashed (exit \(status))"
                    self?.logger?.log("🐍 AGENT | Process terminated (exit \(status))")
                }
            }

            do {
                try proc.run()
                let pid = proc.processIdentifier

                // Update UI state on main thread
                await MainActor.run { [weak self] in
                    self?.process = proc
                    self?.agentStatus = "Connecting..."
                    self?.logger?.log("🐍 AGENT | executablePath: \(execPath)")
                    self?.logger?.log("🐍 AGENT | repoRoot: \(repoRoot.path)")
                    self?.logger?.log("🐍 AGENT | venv python: \(venvPython.path) (exists: \(venvExists))")
                    self?.logger?.log("🐍 AGENT | Python process spawned (pid: \(pid))")
                }

                // Read stderr in background
                Task.detached { [logWriter] in
                    let handle = errPipe.fileHandleForReading
                    for try await line in handle.bytes.lines {
                        let entry = "🐍 ERR | \(line)\n"
                        await logWriter.append(entry)
                    }
                }

                // Read stdout in background
                Task.detached { [logWriter] in
                    let handle = outPipe.fileHandleForReading
                    for try await line in handle.bytes.lines {
                        let entry = "🐍 OUT | \(line)\n"
                        await logWriter.append(entry)
                    }
                }

                // Start SSE subscription after server is ready
                await MainActor.run { [weak self] in
                    self?.sseTask = Task {
                        await self?.waitForHealth()
                        await self?.subscribeToSSE()
                    }
                }
            } catch {
                await MainActor.run { [weak self] in
                    self?.agentStatus = "Failed to start: \(error.localizedDescription)"
                    self?.logger?.log("🐍 AGENT | ❌ Failed to start: \(error)")
                }
            }
        }
    }

    func stop() {
        sseTask?.cancel()
        sseTask = nil
        if let proc = process, proc.isRunning {
            proc.terminate()
            logger?.log("🐍 AGENT | Process terminated")
        }
        process = nil
        isConnected = false
        agentStatus = "Stopped"
    }

    // MARK: - Health Check

    private func waitForHealth() async {
        let healthURL = baseURL.appendingPathComponent("health")
        for _ in 0..<30 {  // Try for 15 seconds (30 × 0.5s)
            do {
                let (_, response) = try await URLSession.shared.data(from: healthURL)
                if let http = response as? HTTPURLResponse, http.statusCode == 200 {
                    agentStatus = "Connected"
                    isConnected = true
                    logger?.log("🐍 AGENT | Health check passed — connected")
                    return
                }
            } catch {
                // Server not ready yet
            }
            try? await Task.sleep(nanoseconds: 500_000_000)
        }
        agentStatus = "Connection timeout"
        logger?.log("🐍 AGENT | ❌ Health check timed out after 15s")
    }

    // MARK: - SSE Subscription

    private func subscribeToSSE() async {
        let eventsURL = baseURL.appendingPathComponent("events")
        var request = URLRequest(url: eventsURL)
        request.timeoutInterval = TimeInterval(Int.max) // SSE is long-lived

        logger?.log("🐍 AGENT | SSE subscribing to \(eventsURL.absoluteString)")

        do {
            let (bytes, response) = try await URLSession.shared.bytes(for: request)
            if let http = response as? HTTPURLResponse {
                logger?.log("🐍 AGENT | SSE connected (HTTP \(http.statusCode))")
            }

            var eventType = ""
            var dataBuffer = ""

            for try await line in bytes.lines {
                if Task.isCancelled { break }

                if line.hasPrefix("event: ") {
                    eventType = String(line.dropFirst(7))
                } else if line.hasPrefix("data: ") {
                    dataBuffer = String(line.dropFirst(6))
                    // Process immediately — AsyncLineSequence skips empty
                    // lines, so we can't rely on the SSE blank-line separator.
                    // Our events always have exactly one event: + one data: line.
                    if eventType == "chat_token" {
                        logger?.logThrottled(
                            "🐍 AGENT | SSE event: type=chat_token",
                            key: "agent-sse-chat-token",
                            minimumInterval: 2.0
                        )
                    } else {
                        logger?.log("🐍 AGENT | SSE event: type=\(eventType)")
                    }
                    handleSSEEvent(type: eventType, data: dataBuffer)
                    eventType = ""
                    dataBuffer = ""
                }
                // Lines starting with ":" are comments (keepalive) — ignore
            }
            logger?.log("🐍 AGENT | SSE stream ended normally")
        } catch {
            if !Task.isCancelled {
                isConnected = false
                agentStatus = "Disconnected — reconnecting..."
                logger?.log("🐍 AGENT | SSE error: \(error.localizedDescription)")
                try? await Task.sleep(nanoseconds: 3_000_000_000)
                if !Task.isCancelled {
                    await waitForHealth()
                    await subscribeToSSE()
                }
            } else {
                logger?.log("🐍 AGENT | SSE cancelled")
            }
        }
    }

    private func handleSSEEvent(type: String, data: String) {
        guard let jsonData = data.data(using: .utf8),
              let dict = try? JSONSerialization.jsonObject(with: jsonData) as? [String: Any] else {
            return
        }

        // Check for internal events (analyzing, analysis_complete)
        if let internalEvent = dict["_event"] as? String {
            switch internalEvent {
            case "analyzing":
                isAnalyzing = true
                agentStatus = "Analyzing feedback..."
            case "analysis_complete":
                isAnalyzing = false
                agentStatus = "Watching for feedback..."
            default:
                break
            }
            return
        }

        switch type {
        case "connected":
            isConnected = true
            agentStatus = "Watching for feedback..."
            // Clean up any interrupted chat streams from a reconnect
            if isChatResponding {
                isChatResponding = false
                if let idx = chatMessages.lastIndex(where: { $0.isStreaming }) {
                    chatMessages[idx].isStreaming = false
                    if chatMessages[idx].text.isEmpty {
                        chatMessages[idx].text = "(interrupted)"
                    }
                }
            }

        case "insight":
            if let card = parseInsightCard(from: dict) {
                insights.append(card)
                logger?.log("🐍 AGENT | Card received: \(card.promptKeyLabel) — \(card.changeDescription.prefix(60))")
            }

        case "chat_token":
            if let text = dict["text"] as? String,
               let messageId = dict["message_id"] as? String {
                handleChatToken(messageId: messageId, text: text)
            }

        case "chat_done":
            if let messageId = dict["message_id"] as? String,
               let fullText = dict["full_text"] as? String {
                handleChatDone(messageId: messageId, fullText: fullText)
            }

        case "chat_tool":
            if let toolName = dict["tool_name"] as? String,
               let messageId = dict["message_id"] as? String {
                let toolInput = dict["tool_input"] as? [String: Any]
                handleChatTool(messageId: messageId, toolName: toolName, toolInput: toolInput)
            }

        case "chat_error":
            let errorMsg = dict["error"] as? String ?? "Unknown error"
            handleChatError(error: errorMsg)

        default:
            break
        }
    }

    // MARK: - User Actions

    func apply(_ card: InsightCard) {
        guard let idx = insights.firstIndex(where: { $0.id == card.id }) else { return }

        Task {
            var request = URLRequest(url: baseURL.appendingPathComponent("apply"))
            request.httpMethod = "POST"
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")

            let body: [String: String] = [
                "suggestion_id": card.suggestionId,
                "prompt_key": card.promptKey,
                "proposed_value": card.proposedValue,
                "saw": card.saw,
                "why": card.why,
                "change": card.changeDescription,
            ]
            request.httpBody = try? JSONSerialization.data(withJSONObject: body)

            do {
                let (_, response) = try await URLSession.shared.data(for: request)
                if let http = response as? HTTPURLResponse, http.statusCode == 200 {
                    insights[idx].status = .applied
                    // Trigger prompt reload in the app
                    NotificationCenter.default.post(name: .promptsDidChange, object: nil)
                    logger?.log("🐍 AGENT | ✅ Applied: \(card.promptKeyLabel)")
                }
            } catch {
                logger?.log("🐍 AGENT | ❌ Apply failed: \(error)")
            }
        }
    }

    func skip(_ card: InsightCard) {
        guard let idx = insights.firstIndex(where: { $0.id == card.id }) else { return }
        insights[idx].status = .skipped

        Task {
            var request = URLRequest(url: baseURL.appendingPathComponent("skip"))
            request.httpMethod = "POST"
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")

            let body: [String: String] = [
                "suggestion_id": card.suggestionId,
                "prompt_key": card.promptKey,
                "saw": card.saw,
                "why": card.why,
                "change": card.changeDescription,
            ]
            request.httpBody = try? JSONSerialization.data(withJSONObject: body)

            _ = try? await URLSession.shared.data(for: request)
            logger?.log("🐍 AGENT | ⏭️ Skipped: \(card.promptKeyLabel)")
        }
    }

    // MARK: - Chat

    func sendChatMessage(_ text: String) {
        let userMsg = ChatMessage(role: .user, text: text)
        chatMessages.append(userMsg)
        isChatResponding = true

        Task {
            var request = URLRequest(url: baseURL.appendingPathComponent("chat"))
            request.httpMethod = "POST"
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            let body: [String: String] = ["message": text]
            request.httpBody = try? JSONSerialization.data(withJSONObject: body)

            do {
                let (_, response) = try await URLSession.shared.data(for: request)
                if let http = response as? HTTPURLResponse, http.statusCode != 200 {
                    logger?.log("🐍 CHAT | POST /chat failed: HTTP \(http.statusCode)")
                    isChatResponding = false
                }
            } catch {
                logger?.log("🐍 CHAT | POST /chat error: \(error)")
                isChatResponding = false
            }
        }
    }

    func clearChat() {
        chatMessages.removeAll()
        isChatResponding = false
        tokenFlushTask?.cancel()
        tokenFlushTask = nil
        tokenBuffer.removeAll()

        Task {
            var request = URLRequest(url: baseURL.appendingPathComponent("chat/clear"))
            request.httpMethod = "POST"
            _ = try? await URLSession.shared.data(for: request)
            logger?.log("🐍 CHAT | History cleared")
        }
    }

    // Token buffering — batch rapid SSE tokens into ~100ms UI updates
    // to avoid overwhelming SwiftUI's view graph with per-token re-renders.
    private var tokenBuffer: [String: String] = [:]
    private var tokenFlushTask: Task<Void, Never>?

    private func handleChatToken(messageId: String, text: String) {
        tokenBuffer[messageId, default: ""] += text

        // Schedule a single flush if not already pending
        if tokenFlushTask == nil {
            tokenFlushTask = Task { @MainActor [weak self] in
                try? await Task.sleep(nanoseconds: 100_000_000) // 100ms
                self?.flushTokenBuffer()
                self?.tokenFlushTask = nil
            }
        }
    }

    private func flushTokenBuffer() {
        guard !tokenBuffer.isEmpty else { return }
        for (messageId, bufferedText) in tokenBuffer {
            if let idx = chatMessages.firstIndex(where: { $0.id == messageId }) {
                chatMessages[idx].text += bufferedText
            } else {
                var msg = ChatMessage(role: .assistant, text: bufferedText, id: messageId)
                msg.isStreaming = true
                chatMessages.append(msg)
            }
        }
        tokenBuffer.removeAll()
    }

    private func handleChatTool(messageId: String, toolName: String, toolInput: [String: Any]?) {
        let label = toolDisplayName(toolName, input: toolInput)
        let detail = toolDetailString(toolName, input: toolInput)
        let toolMsg = ChatMessage(role: .tool, text: label, toolDetail: detail)
        chatMessages.append(toolMsg)
        logger?.log("🐍 CHAT | Tool: \(toolName)")
    }

    /// Short label for the tool indicator row
    private func toolDisplayName(_ name: String, input: [String: Any]?) -> String {
        if name.contains("propose_prompt_change") {
            let key = input?["prompt_key"] as? String ?? ""
            return key.isEmpty ? "Proposing prompt change..." : "Proposing change to \(key)"
        }
        switch name {
        case "Read":
            if let path = input?["file_path"] as? String {
                let filename = (path as NSString).lastPathComponent
                return "Reading \(filename)"
            }
            return "Reading file..."
        case "Bash":
            return "Running command..."
        case "Glob":
            return "Searching files..."
        case "Grep":
            let pattern = input?["pattern"] as? String ?? ""
            return pattern.isEmpty ? "Searching code..." : "Searching for \"\(pattern.prefix(30))\""
        default:
            return "Using \(name)..."
        }
    }

    /// Full detail string shown when expanded
    private func toolDetailString(_ name: String, input: [String: Any]?) -> String? {
        guard let input = input, !input.isEmpty else { return nil }
        // Build a readable summary of the tool input
        var lines: [String] = []
        for (key, value) in input.sorted(by: { $0.key < $1.key }) {
            let valueStr = String(describing: value)
            // Truncate long values
            let display = valueStr.count > 200 ? String(valueStr.prefix(200)) + "..." : valueStr
            lines.append("\(key): \(display)")
        }
        return lines.joined(separator: "\n")
    }

    private func handleChatDone(messageId: String, fullText: String) {
        // Cancel the timer but flush pending tokens first (don't lose them)
        tokenFlushTask?.cancel()
        tokenFlushTask = nil
        flushTokenBuffer()
        tokenBuffer.removeAll()

        if let idx = chatMessages.firstIndex(where: { $0.id == messageId }) {
            chatMessages[idx].text = fullText
            chatMessages[idx].isStreaming = false
        } else {
            // Message wasn't created by token flush — create from full text
            var msg = ChatMessage(role: .assistant, text: fullText, id: messageId)
            msg.isStreaming = false
            chatMessages.append(msg)
        }
        isChatResponding = false
    }

    private func handleChatError(error: String) {
        isChatResponding = false
        let errorMsg = ChatMessage(role: .assistant, text: "Error: \(error)")
        chatMessages.append(errorMsg)
        logger?.log("🐍 CHAT | Error: \(error)")
    }

    // MARK: - Parsing

    private func parseInsightCard(from dict: [String: Any]) -> InsightCard? {
        guard let promptKey = dict["prompt_key"] as? String else { return nil }
        return InsightCard(
            suggestionId: dict["suggestion_id"] as? String ?? UUID().uuidString,
            promptKey: promptKey,
            saw: dict["saw"] as? String ?? "",
            why: dict["why"] as? String ?? "",
            currentValue: dict["current_value"] as? String ?? "",
            proposedValue: dict["proposed_value"] as? String ?? "",
            changeDescription: dict["change_description"] as? String ?? ""
        )
    }
}
