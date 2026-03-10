// MLXEngine.swift
// Swift wrapper around mlx-swift-lm for local LLM inference.
// Replaces LlamaEngine with Apple's MLX framework for 2-3x faster inference on Apple Silicon.
// Uses the same Qwen3.5-4B model but via MLX's unified-memory Metal backend.

import Foundation
import MLXLLM
import MLXLMCommon

actor MLXEngine {
    private var container: ModelContainer?
    private var isLoaded = false

    static let modelId = "mlx-community/Qwen3.5-4B-4bit"

    /// Whether the model is already cached locally (downloaded previously).
    /// mlx-swift-lm caches at ~/Library/Caches/models/
    nonisolated static var isModelCached: Bool {
        let cacheDir = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Caches/models/mlx-community")
        let modelDir = cacheDir.appendingPathComponent("Qwen3.5-4B-4bit")
        return FileManager.default.fileExists(atPath: modelDir.path)
    }

    /// Load model from HuggingFace cache (downloads ~2.5GB on first use).
    func load(progressHandler: (@Sendable (Double) -> Void)? = nil) async throws {
        guard !isLoaded else { return }

        let c = try await loadModelContainer(
            id: Self.modelId,
            progressHandler: { progress in
                progressHandler?(progress.fractionCompleted)
            }
        )

        container = c
        isLoaded = true
    }

    /// Unload model and free memory.
    func unload() {
        container = nil
        isLoaded = false
    }

    var modelLoaded: Bool { isLoaded }

    // MARK: - Non-Streaming Completion

    /// Generate a complete response (blocks until done).
    func complete(prompt: String, systemPrompt: String? = nil, maxTokens: Int = 1024, temperature: Float = 0.7) async throws -> String {
        guard let container = container else {
            throw LocalLLMError.generationFailed("Model not loaded")
        }

        var messages: [Chat.Message] = []
        if let sys = systemPrompt, !sys.isEmpty {
            messages.append(.system(sys))
        }
        messages.append(.user(prompt))

        var userInput = UserInput(chat: messages)
        userInput.additionalContext = ["enable_thinking": false]
        let lmInput = try await container.prepare(input: userInput)

        let parameters = GenerateParameters(
            maxTokens: maxTokens,
            temperature: temperature
        )

        var result = ""
        let stream = try await container.generate(input: lmInput, parameters: parameters)
        for try await generation in stream {
            guard !Task.isCancelled else { throw LocalLLMError.cancelled }
            if case .chunk(let text) = generation {
                result += text
            }
        }

        return result
    }

    // MARK: - Streaming Generation

    /// Stream tokens one at a time. Same signature as the old LlamaEngine.generate().
    func generate(prompt: String, systemPrompt: String? = nil, maxTokens: Int = 1024, temperature: Float = 0.7) -> AsyncThrowingStream<String, Error> {
        AsyncThrowingStream { [weak self] continuation in
            guard let self = self else {
                continuation.finish(throwing: LocalLLMError.generationFailed("Engine deallocated"))
                return
            }
            Task {
                do {
                    try await self.runGeneration(prompt: prompt, systemPrompt: systemPrompt, maxTokens: maxTokens, temperature: temperature, continuation: continuation)
                } catch {
                    continuation.finish(throwing: error)
                }
            }
        }
    }

    private func runGeneration(prompt: String, systemPrompt: String?, maxTokens: Int, temperature: Float, continuation: AsyncThrowingStream<String, Error>.Continuation) async throws {
        guard let container = container else {
            throw LocalLLMError.generationFailed("Model not loaded")
        }

        // Build chat messages
        var messages: [Chat.Message] = []
        if let sys = systemPrompt, !sys.isEmpty {
            messages.append(.system(sys))
        }
        messages.append(.user(prompt))

        // Prepare input with thinking disabled (Qwen3.5 defaults to thinking mode)
        var userInput = UserInput(chat: messages)
        userInput.additionalContext = ["enable_thinking": false]
        let lmInput = try await container.prepare(input: userInput)

        let parameters = GenerateParameters(
            maxTokens: maxTokens,
            temperature: temperature
        )

        // Stream tokens
        let stream = try await container.generate(input: lmInput, parameters: parameters)
        for try await generation in stream {
            guard !Task.isCancelled else {
                continuation.finish(throwing: LocalLLMError.cancelled)
                return
            }
            if case .chunk(let text) = generation {
                continuation.yield(text)
            }
        }

        continuation.finish()
    }
}
