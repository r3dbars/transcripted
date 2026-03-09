// LlamaEngine.swift
// Swift wrapper around llama.cpp C API for local LLM inference.
// Each instance owns one model + context — thread safety via actor isolation.

import Foundation
import llamacpp

actor LlamaEngine {
    private var model: OpaquePointer?   // llama_model*
    private var context: OpaquePointer? // llama_context*
    private var vocab: OpaquePointer?   // llama_vocab* (owned by model, not freed separately)
    private var isLoaded = false

    /// Load a GGUF model from disk.
    func load(path: String, contextSize: UInt32 = 8192) throws {
        guard !isLoaded else { return }

        // Initialize llama.cpp backend (idempotent)
        llama_backend_init()

        // Load model
        var modelParams = llama_model_default_params()
        modelParams.n_gpu_layers = 999  // offload everything to Metal
        guard let m = llama_model_load_from_file(path, modelParams) else {
            throw LocalLLMError.modelLoadFailed("llama_model_load_from_file returned nil for \(path)")
        }
        model = m
        vocab = llama_model_get_vocab(m)

        // Create context
        var ctxParams = llama_context_default_params()
        ctxParams.n_ctx = contextSize
        ctxParams.n_batch = 512
        ctxParams.n_threads = 4
        guard let c = llama_init_from_model(m, ctxParams) else {
            llama_model_free(m)
            model = nil
            vocab = nil
            throw LocalLLMError.modelLoadFailed("llama_init_from_model returned nil")
        }
        context = c
        isLoaded = true
    }

    /// Unload the model and free resources.
    func unload() {
        if let c = context { llama_free(c) }
        if let m = model { llama_model_free(m) }
        context = nil
        model = nil
        vocab = nil
        isLoaded = false
    }

    deinit {
        if let c = context { llama_free(c) }
        if let m = model { llama_model_free(m) }
    }

    var modelLoaded: Bool { isLoaded }

    // MARK: - Non-Streaming Completion

    /// Generate a complete response (blocks until done).
    func complete(prompt: String, systemPrompt: String? = nil, maxTokens: Int = 1024, temperature: Float = 0.7) async throws -> String {
        var result = ""
        for try await token in generate(prompt: prompt, systemPrompt: systemPrompt, maxTokens: maxTokens, temperature: temperature) {
            result += token
        }
        return result
    }

    // MARK: - Streaming Generation

    /// Stream tokens one at a time. Same signature as AnthropicAPI.streamDraft().
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

    private func runGeneration(prompt: String, systemPrompt: String?, maxTokens: Int, temperature: Float, continuation: AsyncThrowingStream<String, Error>.Continuation) throws {
        guard let model = model, let context = context, let vocab = vocab else {
            throw LocalLLMError.generationFailed("Model not loaded")
        }

        // Format prompt using the model's chat template
        let formattedPrompt = formatChatPrompt(systemPrompt: systemPrompt, userMessage: prompt, model: model)

        // Tokenize
        let promptTokens = tokenize(text: formattedPrompt, vocab: vocab)
        guard !promptTokens.isEmpty else {
            throw LocalLLMError.generationFailed("Tokenization produced no tokens")
        }

        let nCtx = Int(llama_n_ctx(context))
        guard promptTokens.count < nCtx else {
            throw LocalLLMError.contextOverflow
        }

        // Clear KV cache for fresh generation
        llama_kv_self_clear(context)

        // Create batch and process prompt
        var batch = llama_batch_init(Int32(promptTokens.count), 0, 1)
        defer { llama_batch_free(batch) }

        for (i, token) in promptTokens.enumerated() {
            llama_batch_add(&batch, token, Int32(i), [llama_seq_id(0)], i == promptTokens.count - 1)
        }

        guard llama_decode(context, batch) == 0 else {
            throw LocalLLMError.generationFailed("Prompt decode failed")
        }

        // Set up sampler chain
        let sampler = createSampler(temperature: temperature, vocab: vocab)
        defer { llama_sampler_free(sampler) }

        // Generate tokens
        let eotToken = llama_vocab_eot(vocab)
        let eosToken = llama_vocab_eos(vocab)
        var nDecoded = 0

        for _ in 0..<maxTokens {
            guard !Task.isCancelled else {
                continuation.finish(throwing: LocalLLMError.cancelled)
                return
            }

            let newToken = llama_sampler_sample(sampler, context, -1)

            // Check for end of generation
            if newToken == eotToken || newToken == eosToken || llama_vocab_is_eog(vocab, newToken) {
                break
            }

            // Convert token to text
            let text = tokenToString(token: newToken, vocab: vocab)
            if !text.isEmpty {
                continuation.yield(text)
            }

            // Prepare next batch
            batch.n_tokens = 0
            llama_batch_add(&batch, newToken, Int32(promptTokens.count + nDecoded), [llama_seq_id(0)], true)
            nDecoded += 1

            guard llama_decode(context, batch) == 0 else {
                throw LocalLLMError.generationFailed("Token decode failed at position \(nDecoded)")
            }
        }

        continuation.finish()
    }

    // MARK: - Chat Template Formatting

    private func formatChatPrompt(systemPrompt: String?, userMessage: String, model: OpaquePointer) -> String {
        // Build ChatML format manually — reliable across all Qwen models
        var parts: [String] = []
        if let sys = systemPrompt, !sys.isEmpty {
            parts.append("<|im_start|>system\n\(sys)<|im_end|>")
        }
        parts.append("<|im_start|>user\n\(userMessage)<|im_end|>")
        parts.append("<|im_start|>assistant\n")
        return parts.joined(separator: "\n")
    }

    // MARK: - Sampler

    private func createSampler(temperature: Float, vocab: OpaquePointer) -> UnsafeMutablePointer<llama_sampler> {
        let sparams = llama_sampler_chain_default_params()
        let chain = llama_sampler_chain_init(sparams)!

        if temperature <= 0 {
            // Greedy sampling
            llama_sampler_chain_add(chain, llama_sampler_init_greedy())
        } else {
            // Temperature + top-p + min-p sampling
            let seed = UInt32.random(in: 0...UInt32.max)
            llama_sampler_chain_add(chain, llama_sampler_init_top_p(0.95, 1))
            llama_sampler_chain_add(chain, llama_sampler_init_min_p(0.05, 1))
            llama_sampler_chain_add(chain, llama_sampler_init_temp(temperature))
            llama_sampler_chain_add(chain, llama_sampler_init_dist(seed))
        }

        return chain
    }

    // MARK: - Tokenization Helpers

    private func tokenize(text: String, vocab: OpaquePointer) -> [llama_token] {
        let utf8 = Array(text.utf8)
        let maxTokens = utf8.count + 16
        var tokens = [llama_token](repeating: 0, count: maxTokens)
        let nTokens = llama_tokenize(vocab, utf8.map { Int8(bitPattern: $0) }, Int32(utf8.count), &tokens, Int32(maxTokens), true, true)
        guard nTokens >= 0 else { return [] }
        return Array(tokens.prefix(Int(nTokens)))
    }

    private func tokenToString(token: llama_token, vocab: OpaquePointer) -> String {
        var buf = [CChar](repeating: 0, count: 256)
        let len = llama_token_to_piece(vocab, token, &buf, Int32(buf.count), 0, true)
        guard len > 0 else { return "" }
        return String(cString: buf.prefix(Int(len)) + [0])
    }
}

// MARK: - llama_batch helpers

private func llama_batch_add(_ batch: inout llama_batch, _ token: llama_token, _ pos: llama_pos, _ seqIds: [llama_seq_id], _ logits: Bool) {
    let i = Int(batch.n_tokens)
    batch.token[i] = token
    batch.pos[i] = pos
    batch.n_seq_id[i] = Int32(seqIds.count)
    for (j, seqId) in seqIds.enumerated() {
        batch.seq_id[i]![j] = seqId
    }
    batch.logits[i] = logits ? 1 : 0
    batch.n_tokens += 1
}
