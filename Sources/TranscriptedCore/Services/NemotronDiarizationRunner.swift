// NemotronDiarizationRunner.swift
// Loads and runs FluidAudio's Nemotron 3 Diarization model for DiarizationService.
//
// `Nemotron3Diarizer` is a synchronous, non-Sendable, not-thread-safe class. This
// runner owns exactly one and only ever touches it on a private serial queue, so
// concurrent `diarizeOffline` calls queue up instead of racing on its streaming
// state, and the long synchronous inference never blocks a Swift concurrency
// thread.

import Foundation
import CoreML
@preconcurrency import FluidAudio

/// Frame-level Nemotron output, copied into plain Swift values.
struct NemotronFrameProbabilities: Sendable {
    /// `[frameCount * numSpeakers]`, frame-major.
    let probabilities: [Float]
    let frameCount: Int
    let numSpeakers: Int
    let frameSeconds: Double
}

final class NemotronDiarizationRunner: @unchecked Sendable {

    /// Lab-only override naming a FluidAudio `Nemotron3Config.preset(named:)`
    /// preset, e.g. `TRANSCRIPTED_NEMOTRON_PRESET=fast32`. Read when the Nemotron
    /// backend initializes; unknown names fall back to the default with a warning.
    static let presetEnvironmentKey = "TRANSCRIPTED_NEMOTRON_PRESET"

    /// `fast128`: best AMI DER of FluidAudio 0.17.0's streaming presets, largest
    /// chunk that still compiles for the Neural Engine, 10.24 s of audio per call.
    /// We diarize whole recordings, so its ~10 s latency does not matter.
    static let defaultPresetName = "fast128"

    /// `ModelBundleProvider` key for a bundled copy of one preset. The directory
    /// must hold the preset's `.mlmodelc` (e.g. `Nemotron3Diarizer_fast128.mlmodelc`)
    /// next to `learnable_sil_emb.bin` (plus `pre_encode_proj_t.bin` for split-graph
    /// presets), flat, as `Nemotron3Models.load(config:directory:)` expects. Nothing
    /// ships this yet; without it the preset is downloaded into
    /// `~/Library/Application Support/FluidAudio/Models/nemotron-3-diarization/`.
    static let bundleDirectoryName = "nemotron-diarizer-models"

    let presetName: String
    private let diarizer: Nemotron3Diarizer
    private let queue = DispatchQueue(label: "com.transcripted.diarization.nemotron", qos: .userInitiated)

    private init(presetName: String, diarizer: Nemotron3Diarizer) {
        self.presetName = presetName
        self.diarizer = diarizer
    }

    // MARK: - Configuration

    /// The preset to load: the environment override when it names a known preset,
    /// otherwise `defaultPresetName`.
    static func resolvePresetName(
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) -> String {
        guard let raw = environment[presetEnvironmentKey]?.trimmingCharacters(in: .whitespacesAndNewlines),
              !raw.isEmpty else {
            return defaultPresetName
        }
        guard Nemotron3Config.preset(named: raw) != nil else {
            AppLogger.transcription.warning("Unknown Nemotron preset override, using default", [
                "preset": raw, "default": Self.defaultPresetName
            ])
            return Self.defaultPresetName
        }
        return raw
    }

    /// The monolithic `offline` preset fails the Neural Engine compiler and must
    /// run on CPU+GPU; every other preset can use the ANE.
    static func computeUnits(forPreset name: String) -> MLComputeUnits {
        (name == "offline" || name.hasPrefix("offline-")) ? .cpuAndGPU : .all
    }

    // MARK: - Loading

    /// Load `presetName` from the bundle when `bundleProvider` has one, else from
    /// FluidAudio's cache (downloading with retry on first use).
    static func load(presetName: String, bundleProvider: ModelBundleProvider) async throws -> NemotronDiarizationRunner {
        guard let config = Nemotron3Config.preset(named: presetName) else {
            throw NSError(domain: "DiarizationService", code: 4, userInfo: [
                NSLocalizedDescriptionKey: "Unknown Nemotron diarization preset"
            ])
        }
        let units = Self.computeUnits(forPreset: presetName)

        let models: Nemotron3Models
        if let bundleDirectory = bundleProvider(Self.bundleDirectoryName) {
            AppLogger.transcription.info("Nemotron diarizer loading from bundle", ["preset": presetName])
            models = try await Nemotron3Models.load(config: config, directory: bundleDirectory, computeUnits: units)
        } else {
            AppLogger.transcription.info("Nemotron diarizer not bundled, loading from cache or downloading", ["preset": presetName])
            models = try await ModelDownloadService.withRetry {
                try await Nemotron3Models.loadFromHuggingFace(config: config, computeUnits: units)
            }
        }
        return NemotronDiarizationRunner(
            presetName: presetName,
            diarizer: Nemotron3Diarizer(config: config, models: models)
        )
    }

    // MARK: - Inference

    /// Run the whole recording through Nemotron. `samples` must be 16 kHz mono.
    /// Calls are serialized on the runner's queue.
    func run(samples: [Float]) async throws -> NemotronFrameProbabilities {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<NemotronFrameProbabilities, Error>) in
            queue.async {
                do {
                    let output = try self.diarizer.processComplete(samples)
                    let config = self.diarizer.config
                    // `outputFrameSeconds` is a Float 0.01; widen without the
                    // float32 rounding error so turn times land on exact 10 ms steps.
                    let frameSeconds = (Double(config.outputFrameSeconds) * 1_000_000).rounded() / 1_000_000
                    continuation.resume(returning: NemotronFrameProbabilities(
                        probabilities: output.probabilities,
                        frameCount: output.frameCount,
                        numSpeakers: config.numSpeakers,
                        frameSeconds: frameSeconds
                    ))
                } catch {
                    continuation.resume(throwing: error)
                }
            }
        }
    }
}
