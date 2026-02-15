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
    private static let apiVersion = "2023-06-01"

    private static let systemPrompt = """
        You are a writing assistant. Take the user's rough spoken text and rewrite it as a clear, \
        well-structured message. Preserve the original meaning, intent, and tone. Don't add \
        information that wasn't in the original. Keep it concise and natural-sounding.
        """

    static func draft(rawText: String, apiKey: String) async throws -> String {
        guard !apiKey.isEmpty else { throw AnthropicAPIError.noAPIKey }

        var request = URLRequest(url: endpoint)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue(apiKey, forHTTPHeaderField: "x-api-key")
        request.setValue(apiVersion, forHTTPHeaderField: "anthropic-version")

        let body = AnthropicRequest(
            model: model,
            max_tokens: 1024,
            system: systemPrompt,
            messages: [AnthropicMessage(role: "user", content: rawText)]
        )

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
