// StreamingChatEngine.swift
// Native Swift streaming chat — bypasses the Python agent subprocess entirely.
//
// Architecture: instead of user → POST Python → Claude SDK → SSE → Swift,
// this goes directly: user → Anthropic streaming API → Swift.
//
// Context (feedback.jsonl, prompts.json, style.md) is injected into the system
// prompt upfront, so the model has full data access without needing Read/Bash tools.
//
// The only tool is propose_prompt_change, which is handled natively in Swift:
// when Claude calls it, we create an InsightCard and fire onInsightProposed.
// Tool results are sent back in a follow-up request so Claude can respond naturally.
//
// This makes chat feel instant — no Python cold start, no SSE relay hop.

import Foundation
import SwiftUI

// MARK: - Streaming Event Types

private enum StreamEvent {
    case textDelta(String)
    case toolUseStart(id: String, name: String)
    case toolInputDelta(String)
    case toolUseStop
    case messageDone
    case error(String)
}

// MARK: - Chat System Prompt

private let chatSystemPromptBase = """
You are Draft's built-in assistant. The user is chatting with you about Draft — \
a macOS app that captures rough spoken thoughts and polishes them into well-crafted messages \
matching the user's writing style.

You have full access to the user's Draft data, which is included below as context. \
Use it to answer questions accurately. Do not ask the user to provide data you already have.

To propose a prompt change, use the propose_prompt_change tool. This creates an insight \
card in the Suggestions section above the chat, which the user can Apply or Skip.

Rules:
- NEVER remove placeholders: {STYLE_SUMMARY}, {USER_NAME}, {APP_NAME}
- NEVER write to files directly — use propose_prompt_change for prompt changes
- Be concise and direct. Skip pleasantries.
"""

// MARK: - Engine

@MainActor
class StreamingChatEngine: ObservableObject {
    @Published var messages: [ChatMessage] = []
    @Published var isResponding = false

    /// Called when Claude proposes a prompt change via the propose_prompt_change tool.
    var onInsightProposed: ((InsightCard) -> Void)?

    // Conversation history for multi-turn context (Anthropic messages format)
    private var history: [[String: Any]] = []

    var promptStore: PromptStore?

    private let dataDir: URL
    private static let endpoint = URL(string: "https://api.anthropic.com/v1/messages")!
    private static let apiVersion = "2023-06-01"

    init() {
        let appSupport = FileManager.default.urls(
            for: .applicationSupportDirectory, in: .userDomainMask
        ).first!
        dataDir = appSupport.appendingPathComponent("Draft", isDirectory: true)
    }

    // MARK: - Public Interface

    func send(text: String, auth: AuthCredential) async {
        guard !isResponding else { return }

        let userMessage = ChatMessage(role: .user, text: text)
        messages.append(userMessage)
        history.append(["role": "user", "content": text])
        isResponding = true

        let systemPrompt = buildSystemPromptWithContext()
        await runConversationTurn(systemPrompt: systemPrompt, auth: auth)

        isResponding = false
    }

    func clear() {
        messages.removeAll()
        history.removeAll()
        isResponding = false
    }

    // MARK: - Context Injection

    private func buildSystemPromptWithContext() -> String {
        var parts = [chatSystemPromptBase]

        if let style = loadFile("style.md"), !style.isEmpty {
            parts.append("\n<style_profile>\n\(style)\n</style_profile>")
        }

        if let prompts = loadFile("prompts.json"), !prompts.isEmpty {
            parts.append("\n<prompts_json>\n\(prompts)\n</prompts_json>")
        }

        if let feedback = loadRecentFeedback(limit: 25) {
            parts.append("\n<recent_feedback_jsonl>\n\(feedback)\n</recent_feedback_jsonl>")
        }

        if let suggestionLog = loadRecentSuggestionLog(limit: 10) {
            parts.append("\n<recent_suggestion_log_jsonl>\n\(suggestionLog)\n</recent_suggestion_log_jsonl>")
        }

        return parts.joined(separator: "\n")
    }

    private func loadFile(_ name: String) -> String? {
        let url = dataDir.appendingPathComponent(name)
        return try? String(contentsOf: url, encoding: .utf8)
    }

    private func loadRecentFeedback(limit: Int) -> String? {
        guard let raw = loadFile("feedback.jsonl") else { return nil }
        let lines = raw.split(separator: "\n", omittingEmptySubsequences: true)
        let recent = lines.suffix(limit)
        return recent.isEmpty ? nil : recent.joined(separator: "\n")
    }

    private func loadRecentSuggestionLog(limit: Int) -> String? {
        guard let raw = loadFile("suggestion_log.jsonl") else { return nil }
        let lines = raw.split(separator: "\n", omittingEmptySubsequences: true)
        let recent = lines.suffix(limit)
        return recent.isEmpty ? nil : recent.joined(separator: "\n")
    }

    // MARK: - Conversation Turn

    /// Run one or more API turns until we get a final text response (no pending tool calls).
    private func runConversationTurn(systemPrompt: String, auth: AuthCredential) async {
        // Create a placeholder assistant message for streaming
        let assistantMsg = ChatMessage(role: .assistant, text: "", id: UUID().uuidString)
        messages.append(assistantMsg)
        let msgId = assistantMsg.id

        var fullText = ""
        var pendingToolId = ""
        var pendingToolName = ""
        var pendingToolInputBuffer = ""
        var encounteredToolUse = false
        var lastCompletedToolId = ""

        do {
            for try await event in streamRequest(systemPrompt: systemPrompt, auth: auth) {
                switch event {
                case .textDelta(let token):
                    fullText += token
                    updateLastMessage(id: msgId, text: fullText, streaming: true)

                case .toolUseStart(let id, let name):
                    encounteredToolUse = true
                    pendingToolId = id
                    pendingToolName = name
                    pendingToolInputBuffer = ""

                case .toolInputDelta(let partial):
                    pendingToolInputBuffer += partial

                case .toolUseStop:
                    lastCompletedToolId = pendingToolId
                    if pendingToolName == "propose_prompt_change" {
                        handleProposePromptChange(
                            toolId: pendingToolId,
                            rawInput: pendingToolInputBuffer
                        )
                    }
                    pendingToolId = ""
                    pendingToolName = ""
                    pendingToolInputBuffer = ""

                case .messageDone:
                    break

                case .error(let msg):
                    updateLastMessage(id: msgId, text: "Error: \(msg)", streaming: false)
                    return
                }
            }
        } catch {
            updateLastMessage(id: msgId, text: "Error: \(error.localizedDescription)", streaming: false)
            EventReporter.shared.capture(level: .error, engine: "chat", event: "chat_api_failed",
                message: error.localizedDescription)
            return
        }

        // Finalize the streaming message
        updateLastMessage(id: msgId, text: fullText, streaming: false)

        // If the model called a tool, we need to send the tool result back and get
        // a final text response. Build the follow-up messages array.
        if encounteredToolUse {
            // Add assistant turn to history (with tool use, if any text was produced)
            var assistantContent: [[String: Any]] = []
            if !fullText.isEmpty {
                assistantContent.append(["type": "text", "text": fullText])
            }
            // We already handled tool calls above — record a minimal tool_use block for history.
            // (We only support propose_prompt_change, so we can use a generic result.)
            let toolId = lastCompletedToolId.isEmpty ? "tool_\(UUID().uuidString.prefix(8))" : lastCompletedToolId
            assistantContent.append([
                "type": "tool_use",
                "id": toolId,
                "name": "propose_prompt_change",
                "input": [:]
            ])
            history.append(["role": "assistant", "content": assistantContent])

            // Add tool result — tool_use_id MUST match the id above
            history.append([
                "role": "user",
                "content": [[
                    "type": "tool_result",
                    "tool_use_id": toolId,
                    "content": "Card emitted successfully."
                ]]
            ])

            // Run one more turn to get Claude's natural follow-up text
            await runFollowUpTurn(systemPrompt: systemPrompt, auth: auth)
        } else {
            // Pure text response — just append to history
            history.append(["role": "assistant", "content": fullText])
        }
    }

    /// Second turn after tool use — gets Claude's verbal response to the tool result.
    private func runFollowUpTurn(systemPrompt: String, auth: AuthCredential) async {
        let followUpMsg = ChatMessage(role: .assistant, text: "", id: UUID().uuidString)
        messages.append(followUpMsg)
        let msgId = followUpMsg.id
        var fullText = ""

        do {
            for try await event in streamRequest(systemPrompt: systemPrompt, auth: auth) {
                switch event {
                case .textDelta(let token):
                    fullText += token
                    updateLastMessage(id: msgId, text: fullText, streaming: true)
                case .messageDone, .toolUseStart, .toolInputDelta, .toolUseStop:
                    break
                case .error(let msg):
                    updateLastMessage(id: msgId, text: "Error: \(msg)", streaming: false)
                    return
                }
            }
        } catch {
            updateLastMessage(id: msgId, text: "Error: \(error.localizedDescription)", streaming: false)
            return
        }

        updateLastMessage(id: msgId, text: fullText, streaming: false)
        history.append(["role": "assistant", "content": fullText])
    }

    // MARK: - Streaming Request

    private func streamRequest(systemPrompt: String, auth: AuthCredential) -> AsyncThrowingStream<StreamEvent, Error> {
        AsyncThrowingStream { continuation in
            Task {
                do {
                    var request = URLRequest(url: Self.endpoint)
                    request.httpMethod = "POST"
                    request.setValue("application/json", forHTTPHeaderField: "Content-Type")
                    request.setValue(Self.apiVersion, forHTTPHeaderField: "anthropic-version")
                    request.setValue("text/event-stream", forHTTPHeaderField: "Accept")
                    auth.apply(to: &request)

                    let model = self.promptStore?.config.draftModel ?? DefaultPrompts.sonnetModel
                    let body: [String: Any] = [
                        "model": model,
                        "max_tokens": 2048,
                        "stream": true,
                        "system": systemPrompt,
                        "messages": history,
                        "tools": [InsightCard.toolDefinition]
                    ]
                    request.httpBody = try JSONSerialization.data(withJSONObject: body)

                    let (bytes, response) = try await URLSession.shared.bytes(for: request)

                    if let http = response as? HTTPURLResponse, http.statusCode != 200 {
                        // Drain error body
                        var errorData = Data()
                        for try await byte in bytes {
                            errorData.append(byte)
                        }
                        let msg = (try? JSONDecoder().decode(AnthropicErrorResponse.self, from: errorData))?.error.message
                            ?? "HTTP \(http.statusCode)"
                        continuation.yield(.error(msg))
                        continuation.finish()
                        return
                    }

                    // Parse SSE stream
                    for try await line in bytes.lines {
                        if line.hasPrefix("data: ") {
                            let json = String(line.dropFirst(6))
                            if json == "[DONE]" { break }
                            guard let data = json.data(using: .utf8),
                                  let dict = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
                            else { continue }

                            let eventType = dict["type"] as? String ?? ""

                            switch eventType {
                            case "content_block_start":
                                if let block = dict["content_block"] as? [String: Any],
                                   let blockType = block["type"] as? String,
                                   blockType == "tool_use",
                                   let id = block["id"] as? String,
                                   let name = block["name"] as? String {
                                    continuation.yield(.toolUseStart(id: id, name: name))
                                }

                            case "content_block_delta":
                                if let delta = dict["delta"] as? [String: Any] {
                                    let deltaType = delta["type"] as? String ?? ""
                                    if deltaType == "text_delta",
                                       let text = delta["text"] as? String {
                                        continuation.yield(.textDelta(text))
                                    } else if deltaType == "input_json_delta",
                                              let partial = delta["partial_json"] as? String {
                                        continuation.yield(.toolInputDelta(partial))
                                    }
                                }

                            case "content_block_stop":
                                continuation.yield(.toolUseStop)

                            case "message_stop":
                                continuation.yield(.messageDone)

                            case "error":
                                let msg = (dict["error"] as? [String: Any])?["message"] as? String ?? "Unknown error"
                                continuation.yield(.error(msg))
                                continuation.finish()
                                return

                            default:
                                break
                            }
                        }
                    }

                    continuation.finish()
                } catch {
                    continuation.yield(.error(error.localizedDescription))
                    continuation.finish()
                }
            }
        }
    }

    // MARK: - Tool Handling

    private func handleProposePromptChange(toolId: String, rawInput: String) {
        guard let data = rawInput.data(using: .utf8),
              let input = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let card = InsightCard.from(toolId: toolId, input: input)
        else {
            EventReporter.shared.capture(level: .warning, engine: "chat", event: "tool_parse_failed",
                message: "Failed to parse propose_prompt_change tool input",
                context: ["tool_id": toolId, "input_length": "\(rawInput.count)"])
            return
        }
        onInsightProposed?(card)
    }

    // MARK: - Helpers

    private func updateLastMessage(id: String, text: String, streaming: Bool) {
        guard let idx = messages.lastIndex(where: { $0.id == id }) else { return }
        messages[idx].text = text
        messages[idx].isStreaming = streaming
    }
}
