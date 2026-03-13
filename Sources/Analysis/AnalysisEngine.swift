// AnalysisEngine.swift
// Native Swift replacement for the Python orchestrator agent.
//
// Watches ~/Library/Application Support/Draft/feedback.jsonl using
// DispatchSource (kernel event-driven, zero polling overhead).
// When enough new entries accumulate, runs local LLM inference
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

    private var minEntries: Int { DraftConstants.analysisMinFeedbackEntries }
    private var debounceSeconds: Double { DraftConstants.analysisDebounceSeconds }
    private let isoFormatter = ISO8601DateFormatter()
    private let suggestionWriter: JSONLWriter

    init() {
        dataDir = FileManager.default.draftAppSupportDir
        suggestionWriter = JSONLWriter(fileURL: dataDir.appendingPathComponent("suggestion_log.jsonl"))
    }

    deinit {
        let source = fileSource
        let task = debounceTask
        let fd = fileDescriptor
        source?.cancel()
        task?.cancel()
        if fd >= 0 { Darwin.close(fd) }
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
        guard fileDescriptor >= 0 else {
            EventReporter.shared.capture(level: .error, engine: "analysis", event: "file_watch_failed",
                message: "Failed to open file descriptor for feedback.jsonl")
            return
        }

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

    /// Reference to local inference — set by DraftAppState after init.
    var localInference: LocalInferenceManager?

    // MARK: - Analysis

    private func runAnalysis(newEntryCount: Int) async {
        guard let localInference = localInference, localInference.isReady else {
            // Model not ready — re-accumulate entries
            pendingNewCount += newEntryCount
            EventReporter.shared.capture(level: .warning, engine: "analysis", event: "analysis_skipped_no_model",
                message: "Skipped analysis of \(newEntryCount) entries — local model not loaded")
            return
        }
        isAnalyzing = true
        defer { isAnalyzing = false }

        let systemPrompt = buildAnalysisSystemPrompt()
        let userMessage = """
            \(newEntryCount) new feedback entries have arrived since the last analysis.
            Read the data provided in the system prompt, find the highest-impact pattern
            (the recurring edit that shows the biggest gap between drafted and accepted text),
            and propose 1–3 focused prompt changes.

            Output your response as a JSON array of objects, each with these fields:
            - "prompt_key": key in prompts.json to change
            - "saw": evidence from the feedback data
            - "why": reasoning about what's wrong
            - "current_value": the current prompt value (relevant section)
            - "proposed_value": the full new value for the key

            Example format:
            [{"prompt_key": "drafting_system", "saw": "...", "why": "...", "current_value": "...", "proposed_value": "..."}]
            """

        do {
            let response = try await localInference.draftEngine.complete(
                prompt: userMessage,
                systemPrompt: systemPrompt,
                maxTokens: DraftConstants.analysisMaxTokens,
                temperature: 0.3
            )

            // Parse JSON array from response
            let cards = parseInsightCards(from: response)
            for card in cards {
                insights.append(card)
            }
        } catch {
            EventReporter.shared.capture(level: .error, engine: "analysis", event: "analysis_failed",
                message: error.localizedDescription)
        }
    }

    private func parseInsightCards(from response: String) -> [InsightCard] {
        // Find JSON array in response (model may include text before/after)
        guard let start = response.firstIndex(of: "["),
              let end = response.lastIndex(of: "]") else { return [] }
        let jsonStr = String(response[start...end])
        guard let data = jsonStr.data(using: .utf8),
              let arr = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]] else { return [] }

        return arr.compactMap { dict in
            InsightCard.from(toolId: UUID().uuidString, input: dict)
        }
    }

    private func buildAnalysisSystemPrompt() -> String {
        var parts = [analysisSystemPromptBase]

        if let feedback = loadRecentLines(from: feedbackURL, limit: DraftConstants.analysisFeedbackLines) {
            parts.append("\n<feedback_jsonl>\n\(feedback)\n</feedback_jsonl>")
        }
        do {
            let prompts = try String(contentsOf: promptsURL, encoding: .utf8)
            parts.append("\n<prompts_json>\n\(prompts)\n</prompts_json>")
        } catch {
            EventReporter.shared.capture(level: .warning, engine: "analysis", event: "analysis_file_read_failed",
                message: error.localizedDescription, context: ["path": promptsURL.path])
        }
        do {
            let style = try String(contentsOf: styleURL, encoding: .utf8)
            parts.append("\n<style_profile>\n\(style)\n</style_profile>")
        } catch {
            EventReporter.shared.capture(level: .warning, engine: "analysis", event: "analysis_file_read_failed",
                message: error.localizedDescription, context: ["path": styleURL.path])
        }
        if let log = loadRecentLines(from: suggestionLogURL, limit: DraftConstants.analysisSuggestionLines) {
            parts.append("\n<suggestion_log_jsonl>\n\(log)\n</suggestion_log_jsonl>")
        }

        return parts.joined(separator: "\n")
    }

    // MARK: - File I/O

    private func countLines(at url: URL) -> Int {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return 0 }
        defer { try? handle.close() }
        var count = 0
        while autoreleasepool(invoking: {
            let chunk = handle.readData(ofLength: 8192)
            guard !chunk.isEmpty else { return false }
            for byte in chunk where byte == 0x0A { count += 1 }
            return true
        }) {}
        return count
    }

    private func loadRecentLines(from url: URL, limit: Int) -> String? {
        let content: String
        do {
            content = try String(contentsOf: url, encoding: .utf8)
        } catch {
            EventReporter.shared.capture(level: .warning, engine: "analysis", event: "analysis_file_read_failed",
                message: error.localizedDescription, context: ["path": url.path, "operation": "loadRecentLines"])
            return nil
        }
        let lines = content.split(separator: "\n", omittingEmptySubsequences: true)
        let recent = lines.suffix(limit)
        return recent.isEmpty ? nil : recent.joined(separator: "\n")
    }

    private func writePromptChange(key: String, value: String) {
        do {
            let data = try Data(contentsOf: promptsURL)
            guard var dict = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                EventReporter.shared.capture(level: .error, engine: "analysis", event: "prompt_write_failed",
                    message: "prompts.json root is not a dictionary", context: ["key": key])
                return
            }
            dict[key] = value
            let newData = try JSONSerialization.data(withJSONObject: dict, options: [.prettyPrinted, .sortedKeys])
            try newData.write(to: promptsURL)
        } catch {
            EventReporter.shared.capture(level: .error, engine: "analysis", event: "prompt_write_failed",
                message: error.localizedDescription, context: ["key": key])
        }
    }

    private func logSuggestion(card: InsightCard, action: String) {
        let entry: [String: Any] = [
            "timestamp": isoFormatter.string(from: Date()),
            "suggestion_id": card.suggestionId,
            "prompt_key": card.promptKey,
            "action": action,
            "saw": card.saw,
            "why": card.why
        ]
        let data: Data
        do {
            data = try JSONSerialization.data(withJSONObject: entry)
        } catch {
            EventReporter.shared.capture(level: .warning, engine: "analysis", event: "suggestion_write_failed",
                message: "Failed to serialize suggestion log entry: \(error.localizedDescription)",
                context: ["action": action, "suggestion_id": card.suggestionId])
            return
        }
        let w = suggestionWriter
        Task { await w.append(data) }
    }
}

// MARK: - Analysis System Prompt

private let analysisSystemPromptBase = """
You are Draft's writing quality optimizer. Analyze the feedback data and propose prompt changes.

Each feedback entry has:
- raw_text: user's spoken voice instructions (what they ASKED the AI to do)
- drafted_text: what the AI produced
- accepted_text: what the user actually sent (after editing)
- formality: (optional) detected communication register (casual/professional/formal)

Use raw_text (voice instructions) to distinguish instruction-following errors from style errors. \
If the user asked for X and the AI didn't do X, propose a prompt change to improve instruction-following. \
If the user's edits go beyond what they asked for, that reveals style patterns — propose style-related changes.

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
        do {
            try FileManager.default.createDirectory(at: self, withIntermediateDirectories: true)
        } catch {
            // Can't call EventReporter.shared.capture() from nonisolated URL extension
            fputs("⚠️ ANALYSIS | failed to create directory \(self.path): \(error.localizedDescription)\n", stderr)
        }
    }
}
