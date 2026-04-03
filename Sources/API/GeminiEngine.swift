// GeminiEngine.swift
// Gemini REST API wrapper with SSE streaming and multimodal (image) support.
// Uses URLSession directly — no external dependencies.

import Foundation

enum GeminiError: LocalizedError {
    case noAPIKey
    case networkError(String)
    case apiError(Int, String)
    case parseError(String)
    case cancelled

    var errorDescription: String? {
        switch self {
        case .noAPIKey: return "No Gemini API key configured"
        case .networkError(let msg): return "Network error: \(msg)"
        case .apiError(let code, let msg): return "API error (\(code)): \(msg)"
        case .parseError(let msg): return "Parse error: \(msg)"
        case .cancelled: return "Generation cancelled"
        }
    }
}

actor GeminiEngine {
    private static let keychainKey = "gemini-api-key"
    private var activeTask: URLSessionDataTask?
    private var isGenerating = false

    // MARK: - API Key Management

    nonisolated static var hasAPIKey: Bool {
        KeychainHelper.load(key: keychainKey) != nil
    }

    nonisolated static var isAvailable: Bool { hasAPIKey }

    nonisolated static func saveAPIKey(_ key: String) {
        guard let data = key.data(using: .utf8) else { return }
        _ = KeychainHelper.save(key: keychainKey, data: data)
    }

    nonisolated static func loadAPIKey() -> String? {
        guard let data = KeychainHelper.load(key: keychainKey) else { return nil }
        return String(data: data, encoding: .utf8)
    }

    nonisolated static func deleteAPIKey() {
        KeychainHelper.delete(key: keychainKey)
    }

    // MARK: - Generation

    /// Stream tokens from Gemini. Returns an AsyncThrowingStream that yields text chunks.
    /// When imageData is provided, the screenshot is sent as an inline image part.
    func generate(
        prompt: String,
        systemPrompt: String? = nil,
        imageData: Data? = nil,
        maxTokens: Int = 1024,
        temperature: Float = 0.7
    ) -> AsyncThrowingStream<String, Error> {
        AsyncThrowingStream { continuation in
            let task = Task {
                defer { Task { await self.clearGenerating() } }

                guard !isGenerating else {
                    continuation.finish(throwing: GeminiError.parseError("Model busy"))
                    return
                }
                isGenerating = true

                guard let apiKey = Self.loadAPIKey() else {
                    continuation.finish(throwing: GeminiError.noAPIKey)
                    return
                }

                let urlString = "\(DraftConstants.geminiBaseURL)/models/\(DraftConstants.geminiModel):streamGenerateContent?alt=sse&key=\(apiKey)"
                guard let url = URL(string: urlString) else {
                    continuation.finish(throwing: GeminiError.parseError("Invalid URL"))
                    return
                }

                let body = buildRequestBody(
                    prompt: prompt,
                    systemPrompt: systemPrompt,
                    imageData: imageData,
                    maxTokens: maxTokens,
                    temperature: temperature
                )

                var request = URLRequest(url: url)
                request.httpMethod = "POST"
                request.setValue("application/json", forHTTPHeaderField: "Content-Type")
                request.timeoutInterval = DraftConstants.geminiRequestTimeout
                request.httpBody = try? JSONSerialization.data(withJSONObject: body)

                do {
                    let (bytes, response) = try await URLSession.shared.bytes(for: request)

                    if let httpResponse = response as? HTTPURLResponse, httpResponse.statusCode != 200 {
                        // Try to read error body
                        var errorBody = ""
                        for try await line in bytes.lines {
                            errorBody += line
                            if errorBody.count > 500 { break }
                        }
                        continuation.finish(throwing: GeminiError.apiError(httpResponse.statusCode, errorBody))
                        return
                    }

                    // Parse SSE stream
                    for try await line in bytes.lines {
                        guard !Task.isCancelled else {
                            continuation.finish(throwing: GeminiError.cancelled)
                            return
                        }

                        // SSE format: "data: {json}"
                        guard line.hasPrefix("data: ") else { continue }
                        let jsonStr = String(line.dropFirst(6))
                        guard !jsonStr.isEmpty else { continue }

                        guard let jsonData = jsonStr.data(using: .utf8),
                              let json = try? JSONSerialization.jsonObject(with: jsonData) as? [String: Any] else {
                            continue
                        }

                        // Extract text from candidates[0].content.parts[0].text
                        if let text = extractText(from: json) {
                            continuation.yield(text)
                        }
                    }

                    continuation.finish()
                } catch {
                    guard !Task.isCancelled else {
                        continuation.finish(throwing: GeminiError.cancelled)
                        return
                    }
                    continuation.finish(throwing: GeminiError.networkError(error.localizedDescription))
                }
            }

            // Store task for cancellation support
            continuation.onTermination = { _ in
                task.cancel()
            }
        }
    }

    /// Non-streaming completion — collects all tokens and returns the full response.
    func complete(
        prompt: String,
        systemPrompt: String? = nil,
        imageData: Data? = nil,
        maxTokens: Int = 1024,
        temperature: Float = 0.7
    ) async throws -> String {
        guard let apiKey = Self.loadAPIKey() else {
            throw GeminiError.noAPIKey
        }

        let urlString = "\(DraftConstants.geminiBaseURL)/models/\(DraftConstants.geminiModel):generateContent?key=\(apiKey)"
        guard let url = URL(string: urlString) else {
            throw GeminiError.parseError("Invalid URL")
        }

        let body = buildRequestBody(
            prompt: prompt,
            systemPrompt: systemPrompt,
            imageData: imageData,
            maxTokens: maxTokens,
            temperature: temperature
        )

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.timeoutInterval = DraftConstants.geminiRequestTimeout
        request.httpBody = try JSONSerialization.data(withJSONObject: body)

        let (data, response) = try await URLSession.shared.data(for: request)

        if let httpResponse = response as? HTTPURLResponse, httpResponse.statusCode != 200 {
            let errorBody = String(data: data, encoding: .utf8) ?? "Unknown error"
            throw GeminiError.apiError(httpResponse.statusCode, errorBody)
        }

        guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw GeminiError.parseError("Invalid JSON response")
        }

        guard let text = extractText(from: json) else {
            throw GeminiError.parseError("No text in response")
        }

        return text
    }

    func cancelGeneration() {
        activeTask?.cancel()
        activeTask = nil
        isGenerating = false
    }

    // MARK: - Private

    private func clearGenerating() {
        isGenerating = false
    }

    private func buildRequestBody(
        prompt: String,
        systemPrompt: String?,
        imageData: Data?,
        maxTokens: Int,
        temperature: Float
    ) -> [String: Any] {
        var body: [String: Any] = [:]

        // System instruction
        if let systemPrompt = systemPrompt, !systemPrompt.isEmpty {
            body["system_instruction"] = [
                "parts": [["text": systemPrompt]]
            ]
        }

        // Content parts: optional image + text
        var parts: [[String: Any]] = []

        if let imageData = imageData {
            parts.append([
                "inline_data": [
                    "mime_type": "image/png",
                    "data": imageData.base64EncodedString()
                ]
            ])
        }

        parts.append(["text": prompt])

        body["contents"] = [["parts": parts]]

        // Generation config
        body["generationConfig"] = [
            "maxOutputTokens": maxTokens,
            "temperature": temperature,
        ]

        return body
    }

    /// Extract text from a Gemini response JSON object.
    /// Handles both streaming chunks and full responses.
    private func extractText(from json: [String: Any]) -> String? {
        guard let candidates = json["candidates"] as? [[String: Any]],
              let first = candidates.first,
              let content = first["content"] as? [String: Any],
              let parts = content["parts"] as? [[String: Any]],
              let firstPart = parts.first,
              let text = firstPart["text"] as? String else {
            return nil
        }
        return text
    }
}
