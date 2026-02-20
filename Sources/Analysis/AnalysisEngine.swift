// AnalysisEngine.swift
// Native Swift replacement for the Python orchestrator agent.
//
// Watches ~/Library/Application Support/Draft/feedback.jsonl using
// DispatchSource (kernel event-driven, zero polling overhead).
// When enough new entries accumulate, calls the Anthropic API directly
// with context injected upfront — no subprocess, no SSE relay, no port.
//
// Replaces: agent/ directory + OrchestratorBridge (analysis portions)

import Foundation
import SwiftUI

@MainActor
class AnalysisEngine: ObservableObject {
    @Published var insights: [InsightCard] = []
    @Published var isAnalyzing = false

    // Status for UI display
    var isConnected: Bool { true }  // Native — always "connected"
    var agentStatus: String { isAnalyzing ? "Analyzing feedback..." : "Watching for feedback..." }

    private let dataDir: URL
    private var feedbackURL: URL { dataDir.appendingPathComponent("feedback.jsonl") }
    private var promptsURL: URL { dataDir.appendingPathComponent("prompts.json") }
    private var styleURL: URL { dataDir.appendingPathComponent("style.md") }
    private var suggestionLogURL: URL { dataDir.appendingPathComponent("suggestion_log.jsonl") }

    private var fileSource: DispatchSourceFileSystemObject?
    private var fileDescriptor: Int32 = -1
    private var lastLineCount = 0
    private var pendingNewCount = 0
    private var debounceTask: Task<Void, Never>?

    private let minEntries = 5
    private let debounceSeconds: Double = 30

    init() {
        let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        dataDir = appSupport.appendingPathComponent("Draft", isDirectory: true)
    }

    func start() {
        dataDir.ensureExists()
        // Count existing entries (don't trigger analysis on startup)
        lastLineCount = countLines(at: feedbackURL)
        startFileWatcher()
    }

    func stop() {
        fileSource?.cancel()
        fileSource = nil
        if fileDescriptor >= 0 {
            Darwin.close(fileDescriptor)
            fileDescriptor = -1
        }
        debounceTask?.cancel()
    }

    // MARK: - User Actions (mirrors OrchestratorBridge interface)

    func addInsight(_ card: InsightCard) {
        insights.append(card)
    }

    func apply(_ card: InsightCard) {
        guard let idx = insights.firstIndex(where: { $0.id == card.id }) else { return }
        insights[idx].status = .applied
        writePromptChange(key: card.promptKey, value: card.proposedValue)
        logSuggestion(card: card, action: "apply")
        NotificationCenter.default.post(name: .promptsDidChange, object: nil)
    }

    func skip(_ card: InsightCard) {
        guard let idx = insights.firstIndex(where: { $0.id == card.id }) else { return }
        insights[idx].status = .skipped
        logSuggestion(card: card, action: "skip")
    }

    // MARK: - File Watching

    private func startFileWatcher() {
        // Create file if it doesn't exist yet so we can watch it
        if !FileManager.default.fileExists(atPath: feedbackURL.path) {
            FileManager.default.createFile(atPath: feedbackURL.path, contents: nil)
        }

        fileDescriptor = open(feedbackURL.path, O_EVTONLY)
        guard fileDescriptor >= 0 else { return }

        let source = DispatchSource.makeFileSystemObjectSource(
            fileDescriptor: fileDescriptor,
            eventMask: .write,
            queue: .main
        )
        source.setEventHandler { [weak self] in
            self?.onFeedbackFileChanged()
        }
        source.setCancelHandler { [weak self] in
            if let fd = self?.fileDescriptor, fd >= 0 {
                Darwin.close(fd)
                self?.fileDescriptor = -1
            }
        }
        source.resume()
        fileSource = source
    }

    private func onFeedbackFileChanged() {
        let currentCount = countLines(at: feedbackURL)
        let newLines = max(0, currentCount - lastLineCount)
        guard newLines > 0 else { return }
        lastLineCount = currentCount
        pendingNewCount += newLines
        scheduleDebounce()
    }

    private func scheduleDebounce() {
        debounceTask?.cancel()
        debounceTask = Task { [weak self] in
            guard let self = self else { return }
            try? await Task.sleep(nanoseconds: UInt64(self.debounceSeconds * 1_000_000_000))
            guard !Task.isCancelled else { return }
            guard self.pendingNewCount >= self.minEntries else { return }
            let count = self.pendingNewCount
            self.pendingNewCount = 0
            await self.runAnalysis(newEntryCount: count)
        }
    }

    // MARK: - Analysis

    private func runAnalysis(newEntryCount: Int) async {
        guard let auth = AuthCredential.load() else { return }
        isAnalyzing = true
        defer { isAnalyzing = false }

        let systemPrompt = buildAnalysisSystemPrompt()
        let userMessage = """
            \(newEntryCount) new feedback entries have arrived since the last analysis.
            Read the data provided in the system prompt, find the highest-impact pattern
            (the recurring edit that shows the biggest gap between drafted and accepted text),
            and propose 1–3 focused prompt changes using the propose_prompt_change tool.
            """

        let tools: [[String: Any]] = [InsightCard.toolDefinition]

        do {
            let result = try await callAPIWithToolUse(
                systemPrompt: systemPrompt,
                userMessage: userMessage,
                tools: tools,
                auth: auth,
                maxTurns: 3
            )
            // Parse tool calls from result and create InsightCards
            for card in result {
                insights.append(card)
            }
        } catch {
            // Analysis failed silently — will retry on next feedback batch
        }
    }

    private func buildAnalysisSystemPrompt() -> String {
        var parts = [analysisSystemPromptBase]

        if let feedback = loadRecentLines(from: feedbackURL, limit: 50) {
            parts.append("\n<feedback_jsonl>\n\(feedback)\n</feedback_jsonl>")
        }
        if let prompts = try? String(contentsOf: promptsURL, encoding: .utf8) {
            parts.append("\n<prompts_json>\n\(prompts)\n</prompts_json>")
        }
        if let style = try? String(contentsOf: styleURL, encoding: .utf8) {
            parts.append("\n<style_profile>\n\(style)\n</style_profile>")
        }
        if let log = loadRecentLines(from: suggestionLogURL, limit: 20) {
            parts.append("\n<suggestion_log_jsonl>\n\(log)\n</suggestion_log_jsonl>")
        }

        return parts.joined(separator: "\n")
    }

    // MARK: - API with Tool Use

    private func callAPIWithToolUse(
        systemPrompt: String,
        userMessage: String,
        tools: [[String: Any]],
        auth: AuthCredential,
        maxTurns: Int
    ) async throws -> [InsightCard] {
        var cards: [InsightCard] = []
        var messages: [[String: Any]] = [["role": "user", "content": userMessage]]

        let endpoint = URL(string: "https://api.anthropic.com/v1/messages")!
        let apiVersion = "2023-06-01"

        for _ in 0..<maxTurns {
            var request = URLRequest(url: endpoint)
            request.httpMethod = "POST"
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.setValue(apiVersion, forHTTPHeaderField: "anthropic-version")
            auth.apply(to: &request)

            let body: [String: Any] = [
                "model": AnthropicAPI.sonnetModel,
                "max_tokens": 4096,
                "system": systemPrompt,
                "messages": messages,
                "tools": tools
            ]
            request.httpBody = try JSONSerialization.data(withJSONObject: body)
            request.timeoutInterval = 60

            let (data, response) = try await URLSession.shared.data(for: request)
            guard let http = response as? HTTPURLResponse, http.statusCode == 200 else {
                break
            }

            guard let dict = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let content = dict["content"] as? [[String: Any]]
            else { break }

            let stopReason = dict["stop_reason"] as? String

            // Collect assistant turn
            messages.append(["role": "assistant", "content": content])

            // Process tool calls
            var toolResults: [[String: Any]] = []
            for block in content {
                guard block["type"] as? String == "tool_use",
                      let toolId = block["id"] as? String,
                      let name = block["name"] as? String,
                      name == "propose_prompt_change",
                      let input = block["input"] as? [String: Any],
                      let card = InsightCard.from(toolId: toolId, input: input)
                else { continue }

                cards.append(card)

                toolResults.append([
                    "type": "tool_result",
                    "tool_use_id": toolId,
                    "content": "Card emitted with suggestion_id: \(toolId)"
                ])
            }

            if toolResults.isEmpty || stopReason == "end_turn" { break }

            // Feed tool results back for next turn
            messages.append(["role": "user", "content": toolResults])
        }

        return cards
    }

    // MARK: - File I/O

    private func countLines(at url: URL) -> Int {
        guard let content = try? String(contentsOf: url, encoding: .utf8) else { return 0 }
        return content.split(separator: "\n", omittingEmptySubsequences: true).count
    }

    private func loadRecentLines(from url: URL, limit: Int) -> String? {
        guard let content = try? String(contentsOf: url, encoding: .utf8) else { return nil }
        let lines = content.split(separator: "\n", omittingEmptySubsequences: true)
        let recent = lines.suffix(limit)
        return recent.isEmpty ? nil : recent.joined(separator: "\n")
    }

    private func writePromptChange(key: String, value: String) {
        guard let data = try? Data(contentsOf: promptsURL),
              var dict = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else { return }
        dict[key] = value
        guard let newData = try? JSONSerialization.data(withJSONObject: dict, options: [.prettyPrinted, .sortedKeys])
        else { return }
        try? newData.write(to: promptsURL)
    }

    private func logSuggestion(card: InsightCard, action: String) {
        let entry: [String: Any] = [
            "timestamp": ISO8601DateFormatter().string(from: Date()),
            "suggestion_id": card.suggestionId,
            "prompt_key": card.promptKey,
            "action": action,
            "saw": card.saw,
            "why": card.why
        ]
        guard let data = try? JSONSerialization.data(withJSONObject: entry),
              let line = String(data: data, encoding: .utf8)
        else { return }
        let lineWithNewline = (line + "\n").data(using: .utf8) ?? Data()
        if FileManager.default.fileExists(atPath: suggestionLogURL.path),
           let handle = try? FileHandle(forWritingTo: suggestionLogURL) {
            defer { try? handle.close() }
            handle.seekToEndOfFile()
            handle.write(lineWithNewline)
        } else {
            try? lineWithNewline.write(to: suggestionLogURL)
        }
    }
}

// MARK: - Analysis System Prompt

private let analysisSystemPromptBase = """
You are Draft's writing quality optimizer. Analyze the feedback data and propose prompt changes.

Each feedback entry has:
- raw_text: user's spoken/typed input
- drafted_text: what Claude produced
- accepted_text: what the user actually sent (after editing)

High edit distance = the AI got it wrong. Find recurring patterns in what users change.

RULES:
- NEVER remove placeholders: {STYLE_SUMMARY}, {USER_NAME}, {APP_NAME}
- Use propose_prompt_change for ALL changes — never suggest writing to files directly
- Propose max 3 focused changes per analysis run
- Check suggestion_log_jsonl: don't re-propose recently skipped changes
- Back every proposal with specific evidence quoted from accepted_text
"""

// MARK: - Notification Names

extension Notification.Name {
    static let promptsDidChange = Notification.Name("promptsDidChange")
}

// MARK: - URL Helper

private extension URL {
    func ensureExists() {
        try? FileManager.default.createDirectory(at: self, withIntermediateDirectories: true)
    }
}
