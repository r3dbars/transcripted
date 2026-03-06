// AnthropicAPI.swift
// URLSession-based client for calling the Anthropic Messages API (Claude).
//
// Accepts AuthCredential instead of a raw API key string, so both API key
// and Claude subscription token auth work transparently.
//
// Types (AnthropicAPIError, request/response Codable structs, isRetryable)
// live in AnthropicAPITypes.swift for testability.

import Foundation

// MARK: - API Client

struct AnthropicAPI {
    #if BETA_BUILD
    static let endpoint = URL(string: "\(BetaConfig.proxyBaseURL)/v1/messages")!
    #else
    static let endpoint = URL(string: "https://api.anthropic.com/v1/messages")!
    #endif
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
        do {
            return try await sendRequest(body: body, auth: auth)
        } catch where AnthropicAPIError.isRetryable(error) {
            Task { @MainActor in
                EventReporter.shared.capture(level: .warning, engine: "anthropic", event: "api_retry",
                    message: "Retrying draft after transient error: \(error.localizedDescription)")
            }
            try await Task.sleep(nanoseconds: DraftConstants.apiRetryDelay)
            return try await sendRequest(body: body, auth: auth)
        }
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
                    // Connection phase — retryable (no tokens yielded yet)
                    func connect() async throws -> (URLSession.AsyncBytes, URLResponse) {
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
                            Task { @MainActor in
                                EventReporter.shared.capture(level: .error, engine: "anthropic", event: "api_stream_error",
                                    message: msg, context: ["status_code": "\(http.statusCode)"])
                            }
                            if http.statusCode == 529 || http.statusCode == 503 {
                                throw AnthropicAPIError.overloaded
                            }
                            throw AnthropicAPIError.apiError(msg)
                        }
                        return (bytes, response)
                    }

                    var bytes: URLSession.AsyncBytes
                    do {
                        (bytes, _) = try await connect()
                    } catch where AnthropicAPIError.isRetryable(error) {
                        Task { @MainActor in
                            EventReporter.shared.capture(level: .warning, engine: "anthropic", event: "api_retry",
                                message: "Retrying stream after transient error: \(error.localizedDescription)")
                        }
                        try await Task.sleep(nanoseconds: DraftConstants.apiRetryDelay)
                        (bytes, _) = try await connect()
                    }

                    // Consumption phase — NOT retryable (tokens already yielded to caller)
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
            guard let result = try await group.next() else {
                group.cancelAll()
                throw CancellationError()
            }
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
            Task { @MainActor in
                EventReporter.shared.capture(level: .error, engine: "anthropic", event: "api_auth_failure",
                    message: "HTTP 401 Unauthorized", context: ["auth_mode": auth.modeName])
            }
            if case .subscriptionToken = auth {
                throw AnthropicAPIError.subscriptionTokenExpired
            }
            throw AnthropicAPIError.apiError("Invalid credentials (HTTP 401)")
        }

        if httpResponse.statusCode == 529 || httpResponse.statusCode == 503 {
            Task { @MainActor in
                EventReporter.shared.capture(level: .warning, engine: "anthropic", event: "api_overloaded",
                    message: "HTTP \(httpResponse.statusCode)", context: ["status_code": "\(httpResponse.statusCode)"])
            }
            throw AnthropicAPIError.overloaded
        }

        if httpResponse.statusCode != 200 {
            let errorMessage: String
            if let errorResponse = try? JSONDecoder().decode(AnthropicErrorResponse.self, from: data) {
                errorMessage = errorResponse.error.message
            } else {
                errorMessage = "HTTP \(httpResponse.statusCode)"
            }
            Task { @MainActor in
                EventReporter.shared.capture(level: .error, engine: "anthropic", event: "api_http_error",
                    message: errorMessage, context: ["status_code": "\(httpResponse.statusCode)"])
            }
            throw AnthropicAPIError.apiError(errorMessage)
        }

        let apiResponse = try JSONDecoder().decode(AnthropicResponse.self, from: data)
        guard let firstBlock = apiResponse.content.first else {
            throw AnthropicAPIError.emptyResponse
        }
        return firstBlock.text
    }
}
