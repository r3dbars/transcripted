// LocalLLMError.swift
// Error types for local LLM inference.

import Foundation

enum LocalLLMError: LocalizedError {
    case modelNotFound(String)
    case modelLoadFailed(String)
    case generationFailed(String)
    case contextOverflow
    case cancelled
    case downloadFailed(String)

    var errorDescription: String? {
        switch self {
        case .modelNotFound(let path): return "Model not found at \(path)"
        case .modelLoadFailed(let reason): return "Failed to load model: \(reason)"
        case .generationFailed(let reason): return "Generation failed: \(reason)"
        case .contextOverflow: return "Input exceeds model context window"
        case .cancelled: return "Generation was cancelled"
        case .downloadFailed(let reason): return "Model download failed: \(reason)"
        }
    }
}
