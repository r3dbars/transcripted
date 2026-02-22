// AnthropicAPI.swift
// URLSession-based client for calling the Anthropic Messages API (Claude).
//
// Accepts AuthCredential instead of a raw API key string, so both API key
// and Claude subscription token auth work transparently.

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
    case noCredential
    case invalidResponse
    case emptyResponse
    case apiError(String)
    case networkError(String)
    case subscriptionTokenExpired  // 401 when using subscription token
    case timeout  // Request exceeded the deadline

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
        }
    }
}

struct AnthropicAPI {
    private static let endpoint = URL(string: "https://api.anthropic.com/v1/messages")!
    static let sonnetModel = "claude-sonnet-4-6-20250514"
    private static let apiVersion = "2023-06-01"

    // MARK: - Text Drafting

    static func draft(
        rawText: String,
        auth: AuthCredential,
        model: String,
        systemPrompt: String? = nil,
        maxTokens: Int = 1024
    ) async throws -> String {
        let body = AnthropicRequest(
            model: model,
            max_tokens: maxTokens,
            system: systemPrompt,
            messages: [AnthropicMessage(role: "user", content: rawText)]
        )
        return try await sendRequest(body: body, auth: auth)
    }

    // MARK: - Streaming Draft

    /// Stream a draft response token by token. Used by DraftSessionController for
    /// real-time text rendering in the overlay (first token ~200ms vs 1-2s for full response).
    static func streamDraft(
        rawText: String,
        auth: AuthCredential,
        model: String,
        systemPrompt: String? = nil,
        maxTokens: Int = 1024
    ) -> AsyncThrowingStream<String, Error> {
        AsyncThrowingStream { continuation in
            Task {
                do {
                    var request = URLRequest(url: endpoint)
                    request.httpMethod = "POST"
                    request.setValue("application/json", forHTTPHeaderField: "Content-Type")
                    request.setValue(apiVersion, forHTTPHeaderField: "anthropic-version")
                    auth.apply(to: &request)

                    var body: [String: Any] = [
                        "model": model,
                        "max_tokens": maxTokens,
                        "stream": true,
                        "messages": [["role": "user", "content": rawText]]
                    ]
                    if let system = systemPrompt { body["system"] = system }
                    request.httpBody = try JSONSerialization.data(withJSONObject: body)

                    let (bytes, response) = try await URLSession.shared.bytes(for: request)
                    if let http = response as? HTTPURLResponse, http.statusCode != 200 {
                        var errData = Data()
                        for try await byte in bytes { errData.append(byte) }
                        let msg = (try? JSONDecoder().decode(AnthropicErrorResponse.self, from: errData))?.error.message
                            ?? "HTTP \(http.statusCode)"
                        continuation.finish(throwing: AnthropicAPIError.apiError(msg))
                        return
                    }

                    for try await line in bytes.lines {
                        if line.hasPrefix("data: ") {
                            let json = String(line.dropFirst(6))
                            if json == "[DONE]" { break }
                            guard let data = json.data(using: .utf8),
                                  let dict = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                                  dict["type"] as? String == "content_block_delta",
                                  let delta = dict["delta"] as? [String: Any],
                                  delta["type"] as? String == "text_delta",
                                  let text = delta["text"] as? String
                            else { continue }
                            continuation.yield(text)
                        }
                    }
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
        }
    }

    // MARK: - Vision Context Extraction

    /// Extract full conversation context from a screenshot as plain text, parsed into CapturedContext
    static func extractStructuredContext(imageData: Data, auth: AuthCredential, model: String, systemPrompt: String) async throws -> CapturedContext {
        let rawText = try await sendVisionRequest(
            imageData: imageData,
            model: model,
            systemPrompt: systemPrompt,
            userText: "Extract the full conversation from this screenshot.",
            auth: auth
        )

        // Optional deep debug path — disabled by default to avoid hot-path console I/O.
        if ProcessInfo.processInfo.environment["DRAFT_DEBUG_VISION_RESPONSE"] == "1" {
            print("🔍 VISION RAW RESPONSE (\(rawText.count) chars):\n\(rawText)")
        }

        return CapturedContext.parse(from: rawText)
    }

    // MARK: - Vision Request Helper

    private static func sendVisionRequest(imageData: Data, model: String, systemPrompt: String, userText: String, auth: AuthCredential) async throws -> String {
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
        request.setValue(apiVersion, forHTTPHeaderField: "anthropic-version")
        auth.apply(to: &request)
        request.httpBody = try JSONSerialization.data(withJSONObject: jsonBody)

        let (data, response) = try await URLSession.shared.data(for: request)
        return try parseResponse(data: data, response: response, auth: auth)
    }

    // MARK: - Shared Request Logic

    private static func sendRequest(body: AnthropicRequest, auth: AuthCredential) async throws -> String {
        var request = URLRequest(url: endpoint)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue(apiVersion, forHTTPHeaderField: "anthropic-version")
        auth.apply(to: &request)
        request.httpBody = try JSONEncoder().encode(body)

        let (data, response) = try await URLSession.shared.data(for: request)
        return try parseResponse(data: data, response: response, auth: auth)
    }

    // MARK: - Shared Response Parsing

    /// Run an async operation with a deadline. Throws CancellationError on timeout.
    static func withTimeout<T: Sendable>(seconds: Double, operation: @escaping @Sendable () async throws -> T) async throws -> T {
        try await withThrowingTaskGroup(of: T.self) { group in
            group.addTask { try await operation() }
            group.addTask {
                try await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
                throw CancellationError()
            }
            let result = try await group.next()!
            group.cancelAll()
            return result
        }
    }

    private static func parseResponse(data: Data, response: URLResponse, auth: AuthCredential) throws -> String {
        guard let httpResponse = response as? HTTPURLResponse else {
            throw AnthropicAPIError.invalidResponse
        }

        // Distinguish expired subscription tokens from invalid API keys
        if httpResponse.statusCode == 401 {
            if case .subscriptionToken = auth {
                throw AnthropicAPIError.subscriptionTokenExpired
            }
            throw AnthropicAPIError.apiError("Invalid credentials (HTTP 401)")
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
