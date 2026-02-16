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

    /// Build the structured context extraction prompt, optionally including the user's name
    private static func contextExtractionPrompt(userName: String?) -> String {
        let nameClause: String
        if let name = userName, !name.isEmpty {
            nameClause = """
                The user's name is \(name). Messages from them are what the user previously said — \
                focus on identifying what OTHER people said that the user would be replying to.
                """
        } else {
            nameClause = """
                Focus on identifying the most recent message that someone sent which the user \
                would likely want to reply to.
                """
        }

        return """
            Analyze this screenshot of a messaging app or email client.
            \(nameClause)

            Extract:
            1. platform — which app is this? (slack, email, imessage, discord, teams, other)
            2. sender — who sent the most recent message the user would reply to? (NOT the user themselves)
            3. message — their exact message text
            4. context — any visible context (channel name, subject line, thread topic)
            5. formality — what formality level fits a reply? (casual, professional, formal)
            6. participants — any other visible participants in the conversation

            Return ONLY valid JSON with no markdown fences, no explanation, just the JSON object:
            {"platform":"...","sender":"...","message":"...","context":"...","formality":"...","participants":"..."}

            If you can't determine a field, use null for its value. \
            Prioritize accuracy of sender and message — those are critical.
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

    // MARK: - Structured Vision Context Extraction

    /// Extract structured context from a screenshot, returning a CapturedContext with parsed fields.
    /// Falls back to raw text if JSON parsing fails.
    static func extractStructuredContext(imageData: Data, apiKey: String, userName: String? = nil) async throws -> CapturedContext {
        guard !apiKey.isEmpty else { throw AnthropicAPIError.noAPIKey }

        let rawText = try await sendVisionRequest(
            imageData: imageData,
            systemPrompt: contextExtractionPrompt(userName: userName),
            userText: "Analyze this screenshot and return the structured JSON.",
            apiKey: apiKey
        )

        // Try to parse as JSON first
        let trimmed = rawText.trimmingCharacters(in: .whitespacesAndNewlines)
        // Strip markdown fences if the model added them despite instructions
        let jsonString = trimmed
            .replacingOccurrences(of: "```json", with: "")
            .replacingOccurrences(of: "```", with: "")
            .trimmingCharacters(in: .whitespacesAndNewlines)

        if let jsonData = jsonString.data(using: .utf8),
           var context = try? JSONDecoder().decode(CapturedContext.self, from: jsonData) {
            // Store raw text as backup
            context.rawText = rawText
            return context
        }

        // JSON parsing failed — fall back to raw text
        var fallback = CapturedContext()
        fallback.rawText = rawText
        return fallback
    }

    // MARK: - Legacy Vision Context Extraction (kept for backward compat)

    static func extractContext(imageData: Data, apiKey: String) async throws -> String {
        let context = try await extractStructuredContext(imageData: imageData, apiKey: apiKey)
        return context.displayText
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
