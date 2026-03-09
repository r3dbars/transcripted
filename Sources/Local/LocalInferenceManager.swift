// LocalInferenceManager.swift
// Owns two LlamaEngine instances: a small one for vision parsing, a larger one for drafting.
// Both load from the app bundle on launch and stay resident.

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
        case .ready: return "Ready"
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

        // Check files exist
        let fm = FileManager.default
        guard fm.fileExists(atPath: visionPath) else {
            modelState = .failed("Vision model not found in bundle")
            EventReporter.shared.capture(level: .error, engine: "local", event: "model_not_found",
                message: "Vision model not found at \(visionPath)")
            return
        }
        guard fm.fileExists(atPath: draftPath) else {
            modelState = .failed("Draft model not found in bundle")
            EventReporter.shared.capture(level: .error, engine: "local", event: "model_not_found",
                message: "Draft model not found at \(draftPath)")
            return
        }

        // Load both models (vision first — smaller, loads faster)
        do {
            try await visionEngine.load(path: visionPath, contextSize: 4096)
        } catch {
            modelState = .failed("Vision model: \(error.localizedDescription)")
            EventReporter.shared.capture(level: .error, engine: "local", event: "model_load_failed",
                message: "Vision model load failed: \(error.localizedDescription)")
            return
        }

        do {
            try await draftEngine.load(path: draftPath, contextSize: 8192)
        } catch {
            modelState = .failed("Draft model: \(error.localizedDescription)")
            EventReporter.shared.capture(level: .error, engine: "local", event: "model_load_failed",
                message: "Draft model load failed: \(error.localizedDescription)")
            return
        }

        modelState = .ready
        EventReporter.shared.capture(level: .info, engine: "local", event: "models_loaded",
            message: "Both LLM models loaded successfully")
    }

    func cleanup() {
        Task {
            await visionEngine.unload()
            await draftEngine.unload()
        }
        modelState = .notLoaded
    }
}
