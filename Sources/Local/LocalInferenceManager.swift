// LocalInferenceManager.swift
// Owns a single MLXEngine for drafting, style refinement, and analysis.
// Downloads the Qwen3.5-4B-4bit model from HuggingFace on first use (~2.5GB),
// then loads from cache on subsequent launches.

import Foundation
import SwiftUI

enum ModelState: Equatable {
    case notLoaded
    case downloading(progress: Double)
    case loading
    case ready
    case failed(String)
}

@MainActor
class LocalInferenceManager: ObservableObject {
    @Published var modelState: ModelState = .notLoaded

    let draftEngine = MLXEngine()

    var isReady: Bool {
        if case .ready = modelState { return true }
        return false
    }

    var statusLabel: String {
        switch modelState {
        case .notLoaded: return "Model not loaded"
        case .downloading(let progress):
            let pct = Int(progress * 100)
            return "Downloading model (\(pct)%)..."
        case .loading: return "Loading model..."
        case .ready: return "Ready"
        case .failed(let reason): return "Failed: \(reason)"
        }
    }

    func initialize() async {
        // If already cached, show "loading" — otherwise show download progress
        if MLXEngine.isModelCached {
            modelState = .loading
        } else {
            modelState = .downloading(progress: 0)
        }

        do {
            try await draftEngine.load(progressHandler: { [weak self] progress in
                Task { @MainActor [weak self] in
                    guard let self = self else { return }
                    // Only update download progress if we're in downloading state
                    if case .downloading = self.modelState {
                        self.modelState = .downloading(progress: progress)
                    }
                }
            })
            modelState = .ready
            EventReporter.shared.capture(level: .info, engine: "local", event: "model_loaded",
                message: "MLX model loaded (\(MLXEngine.modelId))")
        } catch {
            modelState = .failed(error.localizedDescription)
            EventReporter.shared.capture(level: .error, engine: "local", event: "model_load_failed",
                message: "MLX model load failed: \(error.localizedDescription)")
        }
    }

    func cleanup() {
        Task {
            await draftEngine.unload()
        }
        modelState = .notLoaded
    }
}
