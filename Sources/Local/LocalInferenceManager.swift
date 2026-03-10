// LocalInferenceManager.swift
// Owns two LlamaEngine instances: a small one for vision parsing, a larger one for drafting.
// Draft model is required; vision model is optional (degrades to voice-only if missing).

import Foundation
import SwiftUI

enum ModelState {
    case notLoaded
    case loading
    case ready
    case failed(String)
}

@MainActor
class LocalInferenceManager: ObservableObject {
    @Published var modelState: ModelState = .notLoaded
    @Published var visionAvailable = false

    let visionEngine = LlamaEngine()
    let draftEngine = LlamaEngine()

    /// Model file names in the app bundle's Resources/llm-models/
    private static let visionModelName = "vision-parser.gguf"
    private static let draftModelName = "draft-model.gguf"

    var isReady: Bool {
        if case .ready = modelState { return true }
        return false
    }

    var statusLabel: String {
        switch modelState {
        case .notLoaded: return "Models not loaded"
        case .loading: return "Loading models..."
        case .ready:
            return visionAvailable ? "Ready" : "Ready (no vision)"
        case .failed(let reason): return "Failed: \(reason)"
        }
    }

    func initialize() async {
        modelState = .loading

        // Find models in bundle
        let modelsDir: String
        if let bundlePath = Bundle.main.resourcePath {
            modelsDir = bundlePath + "/llm-models"
        } else {
            modelState = .failed("No bundle resource path")
            return
        }

        let visionPath = modelsDir + "/" + Self.visionModelName
        let draftPath = modelsDir + "/" + Self.draftModelName

        // Draft model is required
        let fm = FileManager.default
        guard fm.fileExists(atPath: draftPath) else {
            modelState = .failed("Draft model not found in bundle")
            EventReporter.shared.capture(level: .error, engine: "local", event: "model_not_found",
                message: "Draft model not found at \(draftPath)")
            return
        }

        // Load draft model (required)
        do {
            try await draftEngine.load(path: draftPath, contextSize: 8192)
        } catch {
            modelState = .failed("Draft model: \(error.localizedDescription)")
            EventReporter.shared.capture(level: .error, engine: "local", event: "model_load_failed",
                message: "Draft model load failed: \(error.localizedDescription)")
            return
        }

        // Load vision model (optional — degrades to voice-only if missing)
        if fm.fileExists(atPath: visionPath) {
            do {
                try await visionEngine.load(path: visionPath, contextSize: 4096)
                visionAvailable = true
            } catch {
                EventReporter.shared.capture(level: .warning, engine: "local", event: "vision_model_load_failed",
                    message: "Vision model load failed: \(error.localizedDescription)")
            }
        } else {
            EventReporter.shared.capture(level: .info, engine: "local", event: "vision_model_missing",
                message: "Vision model not found — context extraction disabled")
        }

        modelState = .ready
        let visionStatus = visionAvailable ? "vision + draft" : "draft only"
        EventReporter.shared.capture(level: .info, engine: "local", event: "models_loaded",
            message: "LLM models loaded (\(visionStatus))")
    }

    func cleanup() {
        Task {
            await visionEngine.unload()
            await draftEngine.unload()
        }
        visionAvailable = false
        modelState = .notLoaded
    }
}
