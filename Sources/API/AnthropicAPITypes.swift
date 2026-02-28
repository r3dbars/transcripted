// AnthropicAPITypes.swift
// Shared types for the Anthropic API client — error enum, request/response Codable structs.
// Extracted for testability (no EventReporter dependency).

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

// MARK: - Error Enum

enum AnthropicAPIError: LocalizedError {
    case noCredential
    case invalidResponse
    case emptyResponse
    case apiError(String)
    case networkError(String)
    case subscriptionTokenExpired  // 401 when using subscription token
    case timeout  // Request exceeded the deadline
    case overloaded  // 529/503 — Anthropic API temporarily overloaded

    var errorDescription: String? {
        switch self {
        case .noCredential: return "No API credentials configured"
        case .invalidResponse: return "Invalid response from API"
        case .emptyResponse: return "Empty response from API"
        case .apiError(let msg): return msg
        case .networkError(let msg): return "Network error: \(msg)"
        case .subscriptionTokenExpired:
            return "Claude subscription token expired — run `claude setup-token` and update in settings"
        case .timeout:
            return "Request exceeded the deadline"
        case .overloaded:
            return "Anthropic API is temporarily overloaded — try again in a moment"
        }
    }
}

extension AnthropicAPIError {
    static func isRetryable(_ error: Error) -> Bool {
        if let apiErr = error as? AnthropicAPIError, case .overloaded = apiErr { return true }
        if let urlErr = error as? URLError {
            return [.notConnectedToInternet, .networkConnectionLost, .timedOut].contains(urlErr.code)
        }
        return false
    }
}
