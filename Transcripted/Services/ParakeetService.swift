// ParakeetService.swift
// Local speech-to-text using FluidAudio's Parakeet TDT V3 CoreML model.
// Batch transcription only (no live streaming — Transcripted records first, then transcribes).

import Foundation
import FluidAudio

enum ParakeetModelState: Equatable {
    case notLoaded
    case loading
    case ready
    case failed(String)
}

@available(macOS 14.0, *)
@MainActor
class ParakeetService: ObservableObject {
    @Published var modelState: ParakeetModelState = .notLoaded

    private var asrManager: AsrManager?

    var isReady: Bool { asrManager?.isAvailable ?? false }

    // MARK: - Model Initialization

    /// Load Parakeet models from the app bundle.
    /// Expected layout: Contents/Resources/parakeet-models/parakeet-tdt-0.6b-v3-coreml/
    func initialize() async {
        guard asrManager == nil else {
            AppLogger.transcription.debug("Parakeet already initialized")
            return
        }

        modelState = .loading
        AppLogger.transcription.info("Parakeet initializing models")

        do {
            let models: AsrModels
            let loadSource: String

            if let bundlePath = bundledModelsPath() {
                AppLogger.transcription.info("Parakeet loading from bundle", ["path": bundlePath.path])
                models = try await AsrModels.load(from: bundlePath, version: .v3)
                loadSource = "bundle"
            } else {
                // Fallback: download from HuggingFace (~600MB on first run)
                AppLogger.transcription.info("Parakeet models not bundled, downloading (~600MB)")
                models = try await AsrModels.downloadAndLoad(version: .v3)
                loadSource = "download"
            }

            let manager = AsrManager(config: .default)
            try await manager.initialize(models: models)

            asrManager = manager
            modelState = .ready
            AppLogger.transcription.info("Parakeet models loaded and ready", ["source": loadSource])
        } catch {
            modelState = .failed(error.localizedDescription)
            AppLogger.transcription.error("Parakeet model initialization failed", ["error": "\(error.localizedDescription)"])
        }
    }

    /// Check for Parakeet models bundled inside the app at build time.
    private func bundledModelsPath() -> URL? {
        guard let resourcePath = Bundle.main.resourcePath else { return nil }
        let path = URL(fileURLWithPath: resourcePath)
            .appendingPathComponent("parakeet-models")
            .appendingPathComponent("parakeet-tdt-0.6b-v3-coreml")
        let encoderPath = path.appendingPathComponent("Encoder.mlmodelc")
        guard FileManager.default.fileExists(atPath: encoderPath.path) else { return nil }
        return path
    }

    // MARK: - Batch Transcription

    /// Transcribe a WAV file. Loads, resamples to 16kHz, and runs Parakeet.
    nonisolated func transcribe(audioURL: URL) async throws -> String {
        guard let manager = await MainActor.run(body: { self.asrManager }),
              manager.isAvailable else {
            throw PipelineError.modelNotLoaded(model: "Parakeet")
        }

        let samples = try AudioResampler.loadAndResample(url: audioURL, targetRate: 16000)
        AppLogger.transcription.info("Parakeet transcribing", ["samples": "\(samples.count)", "duration": "\(String(format: "%.1f", Double(samples.count) / 16000))s"])

        let result = try await manager.transcribe(samples, source: .microphone)
        let text = result.text.trimmingCharacters(in: .whitespacesAndNewlines)
        AppLogger.transcription.info("Parakeet transcription complete", ["preview": "\(text.prefix(80))...", "confidence": "\(String(format: "%.2f", result.confidence))"])
        return text
    }

    /// Transcribe pre-loaded samples (already at 16kHz mono).
    /// Used for per-speaker-segment transcription after Sortformer diarization.
    nonisolated func transcribeSegment(samples: [Float], source: AudioSource = .system) async throws -> String {
        guard let manager = await MainActor.run(body: { self.asrManager }),
              manager.isAvailable else {
            throw PipelineError.modelNotLoaded(model: "Parakeet")
        }

        let result = try await manager.transcribe(samples, source: source)
        return result.text.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    // MARK: - Cleanup

    func cleanup() {
        asrManager?.cleanup()
        asrManager = nil
        modelState = .notLoaded
    }
}
