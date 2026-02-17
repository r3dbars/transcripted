// AnthropicAPI.swift
// URLSession-based client for calling the Anthropic Messages API (Claude Haiku)

import Foundation

// MARK: - Request/Response Types

struct AnthropicMessage: Codable {
    let role: String
    let content: String
}

struct AnthropicRequest: Codable {
    let model: String
    let max_tokens: Int
    let system: String?
    let messages: [AnthropicMessage]
}

struct AnthropicContentBlock: Codable {
    let type: String
    let text: String
}

struct AnthropicResponse: Codable {
    let id: String
    let content: [AnthropicContentBlock]
    let stop_reason: String?
}

struct AnthropicErrorDetail: Codable {
    let type: String
    let message: String
}

struct AnthropicErrorResponse: Codable {
    let type: String
    let error: AnthropicErrorDetail
}

// MARK: - API Client

enum AnthropicAPIError: LocalizedError {
    case noAPIKey
    case invalidResponse
    case emptyResponse
    case apiError(String)
    case networkError(String)

    var errorDescription: String? {
        switch self {
        case .noAPIKey: return "No API key configured"
        case .invalidResponse: return "Invalid response from API"
        case .emptyResponse: return "Empty response from API"
        case .apiError(let msg): return msg
        case .networkError(let msg): return "Network error: \(msg)"
        }
    }
}

struct AnthropicAPI {
    private static let endpoint = URL(string: "https://api.anthropic.com/v1/messages")!
    private static let model = "claude-haiku-4-5-20251001"
    static let sonnetModel = "claude-sonnet-4-20250514"
    private static let apiVersion = "2023-06-01"

    private static let systemPrompt = """
        You are a writing assistant. Take the user's rough spoken text and rewrite it as a clear, \
        well-structured message. Preserve the original meaning, intent, and tone. Don't add \
        information that wasn't in the original. Keep it concise and natural-sounding.
        """

    /// Build the context extraction prompt — extracts the full conversation thread as plain text
    private static func contextExtractionPrompt(userName: String?, appName: String?) -> String {
        let nameClause: String
        if let name = userName, !name.isEmpty {
            nameClause = "The user's name is \(name). They are one of the participants in this conversation."
        } else {
            nameClause = "Identify the user based on which side of the conversation they appear on."
        }

        let appClause: String
        if let app = appName, !app.isEmpty {
            appClause = "This screenshot is from the app \"\(app)\"."
        } else {
            appClause = "Identify which messaging app this is from the UI."
        }

        return """
            You are extracting a conversation from a screenshot.

            \(appClause)
            \(nameClause)

            IMPORTANT RULES:
            - Focus on the MAIN conversation area — the active chat thread or email body. \
            Ignore sidebars (contact lists, channel lists, conversation previews), navigation bars, \
            notification badges, and other UI chrome. The main conversation is in the center or right panel.
            - For TALKING TO: look at the conversation HEADER or TITLE BAR at the top of the chat — \
            this shows the contact name or group name. Do NOT confuse names mentioned INSIDE messages \
            with the conversation partner. The header/title is the source of truth.
            - Preserve ALL text exactly as written — including emoji, typos, slang, and formatting. \
            Do NOT clean up, rephrase, or "fix" the text. Accuracy matters more than readability.
            - If a speaker name is unclear, use "Unknown".
            - If you're uncertain about any text, include your best guess with a [?] marker.
            - Skip UI elements: buttons, timestamps, reaction counts, read receipts, typing indicators.
            - If you see code blocks or formatted text within messages, keep the formatting.

            Extract the FULL visible conversation — every message, in order, with sender names.

            Return your response in this EXACT plain-text format (no markdown fences, no JSON):

            PLATFORM: [slack/email/imessage/discord/teams/other]
            TALKING TO: [name from the conversation header/title — NOT the user, NOT names mentioned in messages]
            FORMALITY: [casual/professional/formal]

            CONVERSATION:
            [Sender Name]: [their message]
            [Other Sender]: [their message]
            ...

            Example output:
            PLATFORM: imessage
            TALKING TO: Nate
            FORMALITY: casual

            CONVERSATION:
            Nate: Hey, can we sync on the curriculum next week?
            Justin: Sounds great! Tuesday works for me 👍

            Include every visible message in chronological order. Preserve the actual text exactly. \
            Use each sender's display name as shown on screen. This will be used as context for \
            drafting a reply, so accuracy of the original text is critical.
            """
    }

    // MARK: - Text Drafting

    static func draft(rawText: String, apiKey: String, systemPrompt customPrompt: String? = nil, maxTokens: Int = 1024, useModel: String? = nil) async throws -> String {
        guard !apiKey.isEmpty else { throw AnthropicAPIError.noAPIKey }

        let body = AnthropicRequest(
            model: useModel ?? model,
            max_tokens: maxTokens,
            system: customPrompt ?? systemPrompt,
            messages: [AnthropicMessage(role: "user", content: rawText)]
        )

        return try await sendRequest(body: body, apiKey: apiKey)
    }

    // MARK: - Vision Context Extraction

    /// Extract full conversation context from a screenshot as plain text, parsed into CapturedContext
    static func extractStructuredContext(imageData: Data, apiKey: String, userName: String? = nil, appName: String? = nil) async throws -> CapturedContext {
        guard !apiKey.isEmpty else { throw AnthropicAPIError.noAPIKey }

        let rawText = try await sendVisionRequest(
            imageData: imageData,
            systemPrompt: contextExtractionPrompt(userName: userName, appName: appName),
            userText: "Extract the full conversation from this screenshot.",
            apiKey: apiKey
        )

        // Debug: log the raw Haiku response so we can see what came back
        print("🔍 VISION RAW RESPONSE (\(rawText.count) chars):\n\(rawText)")

        return CapturedContext.parse(from: rawText)
    }

    // MARK: - Vision Request Helper

    private static func sendVisionRequest(imageData: Data, systemPrompt: String, userText: String, apiKey: String) async throws -> String {
        let base64Image = imageData.base64EncodedString()

        let jsonBody: [String: Any] = [
            "model": model,
            "max_tokens": 2048,
            "system": systemPrompt,
            "messages": [
                [
                    "role": "user",
                    "content": [
                        [
                            "type": "image",
                            "source": [
                                "type": "base64",
                                "media_type": "image/png",
                                "data": base64Image
                            ]
                        ],
                        [
                            "type": "text",
                            "text": userText
                        ]
                    ]
                ]
            ]
        ]

        var request = URLRequest(url: endpoint)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue(apiKey, forHTTPHeaderField: "x-api-key")
        request.setValue(apiVersion, forHTTPHeaderField: "anthropic-version")
        request.httpBody = try JSONSerialization.data(withJSONObject: jsonBody)

        let (data, response) = try await URLSession.shared.data(for: request)

        guard let httpResponse = response as? HTTPURLResponse else {
            throw AnthropicAPIError.invalidResponse
        }

        if httpResponse.statusCode != 200 {
            if let errorResponse = try? JSONDecoder().decode(AnthropicErrorResponse.self, from: data) {
                throw AnthropicAPIError.apiError(errorResponse.error.message)
            }
            throw AnthropicAPIError.apiError("HTTP \(httpResponse.statusCode)")
        }

        let apiResponse = try JSONDecoder().decode(AnthropicResponse.self, from: data)

        guard let firstBlock = apiResponse.content.first else {
            throw AnthropicAPIError.emptyResponse
        }

        return firstBlock.text
    }

    // MARK: - Shared Request Logic

    private static func sendRequest(body: AnthropicRequest, apiKey: String) async throws -> String {
        var request = URLRequest(url: endpoint)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue(apiKey, forHTTPHeaderField: "x-api-key")
        request.setValue(apiVersion, forHTTPHeaderField: "anthropic-version")
        request.httpBody = try JSONEncoder().encode(body)

        let (data, response) = try await URLSession.shared.data(for: request)

        guard let httpResponse = response as? HTTPURLResponse else {
            throw AnthropicAPIError.invalidResponse
        }

        if httpResponse.statusCode != 200 {
            if let errorResponse = try? JSONDecoder().decode(AnthropicErrorResponse.self, from: data) {
                throw AnthropicAPIError.apiError(errorResponse.error.message)
            }
            throw AnthropicAPIError.apiError("HTTP \(httpResponse.statusCode)")
        }

        let apiResponse = try JSONDecoder().decode(AnthropicResponse.self, from: data)

        guard let firstBlock = apiResponse.content.first else {
            throw AnthropicAPIError.emptyResponse
        }

        return firstBlock.text
    }
}
