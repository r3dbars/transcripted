// NemotronDiarizationRunner.swift
// Loads and runs FluidAudio's Nemotron 3 Diarization model for DiarizationService.
//
// `Nemotron3Diarizer` is a synchronous, non-Sendable, not-thread-safe class. This
// runner keeps the loaded models and builds a fresh diarizer for each run, only
// ever on a private serial queue, so concurrent `diarizeOffline` calls queue up
// instead of racing, and the long synchronous inference never blocks a Swift
// concurrency thread.
//
// The recording is fed through the diarizer's streaming API in 10 s slices rather
// than `processComplete`, which holds a padded copy of the whole recording plus its
// whole mel spectrogram (about +0.42 GB per hour of audio at the job's peak). Same
// model calls on bit-identical chunk features, so the output is identical.

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

    /// Samples appended to the streaming diarizer per call
    /// (`DiarizationBackend.nemotronSliceSeconds` at 16 kHz). One whole-buffer
    /// append would copy the recording into the frontend, so feed it in slices.
    static let feedSliceSamples = DiarizationBackend.nemotronSliceSamples

    let presetName: String
    /// Loaded once; only touched on `queue`.
    private let config: Nemotron3Config
    private let models: Nemotron3Models
    private let queue = DispatchQueue(label: "com.transcripted.diarization.nemotron", qos: .userInitiated)

    /// Internal so model-gated tests can hand in preloaded models.
    init(presetName: String, config: Nemotron3Config, models: Nemotron3Models) {
        self.presetName = presetName
        self.config = config
        self.models = models
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

    /// Load `presetName` from a local directory when `bundleProvider` has one
    /// (flat bundle or a HuggingFace cache passed as local), else from
    /// FluidAudio's cache (downloading with retry on first use).
    /// `allowDownload: false` never calls `loadFromHuggingFace`.
    static func load(
        presetName: String,
        bundleProvider: ModelBundleProvider,
        allowDownload: Bool = true
    ) async throws -> NemotronDiarizationRunner {
        guard let config = Nemotron3Config.preset(named: presetName) else {
            throw NSError(domain: "DiarizationService", code: 4, userInfo: [
                NSLocalizedDescriptionKey: "Unknown Nemotron diarization preset"
            ])
        }
        let units = Self.computeUnits(forPreset: presetName)

        let models: Nemotron3Models
        if let bundleDirectory = bundleProvider(Self.bundleDirectoryName) {
            AppLogger.transcription.info("Nemotron diarizer loading from local directory", ["preset": presetName])
            let local = try directoryForLocalLoad(from: bundleDirectory, preset: presetName)
            models = try await Nemotron3Models.load(config: config, directory: local, computeUnits: units)
        } else {
            guard allowDownload else {
                throw DiarizationDownloadDisabled(backend: DiarizationBackend.nemotron.rawValue)
            }
            AppLogger.transcription.info("Nemotron diarizer not bundled, loading from cache or downloading", ["preset": presetName])
            models = try await ModelDownloadService.withRetry {
                try await Nemotron3Models.loadFromHuggingFace(config: config, computeUnits: units)
            }
        }
        return NemotronDiarizationRunner(presetName: presetName, config: config, models: models)
    }

    /// Flat bundle as-is. HuggingFace cache (`monolithic/v2/…` plus companions
    /// at the root) is staged into a temp flat directory of symlinks so
    /// `Nemotron3Models.load` never goes through HuggingFace.
    static func directoryForLocalLoad(from directory: URL, preset: String) throws -> URL {
        guard let files = DiarizationBackend.nemotronLocalLoadFiles(in: directory, preset: preset) else {
            throw DiarizationDownloadDisabled(backend: DiarizationBackend.nemotron.rawValue)
        }
        let modelName = DiarizationBackend.nemotronModelFileName(preset: preset)
        let parent = files.model.deletingLastPathComponent()
        let alreadyFlat = files.model.lastPathComponent == modelName
            && files.companions.allSatisfy { $0.deletingLastPathComponent() == parent }
        if alreadyFlat { return parent }

        let staged = FileManager.default.temporaryDirectory
            .appendingPathComponent("nemotron-local-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: staged, withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(
            at: staged.appendingPathComponent(modelName),
            withDestinationURL: files.model
        )
        for companion in files.companions {
            try FileManager.default.createSymbolicLink(
                at: staged.appendingPathComponent(companion.lastPathComponent),
                withDestinationURL: companion
            )
        }
        return staged
    }

    // MARK: - Inference

    /// Run the whole recording through Nemotron. `samples` must be 16 kHz mono.
    /// Calls are serialized on the runner's queue.
    func run(samples: [Float]) async throws -> NemotronFrameProbabilities {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<NemotronFrameProbabilities, Error>) in
            queue.async {
                do {
                    let config = self.config
                    // Fresh per run: `reset()` keeps the frontend's buffers, and this
                    // runner lives for the whole app session.
                    let diarizer = Nemotron3Diarizer(config: config, models: self.models)
                    let speakers = config.numSpeakers
                    var probabilities = [Float]()
                    // ~1 frame per 160 samples (10 ms); sized from the frame count,
                    // never from samples.count.
                    probabilities.reserveCapacity((samples.count / 160 + 2) * speakers)
                    var start = 0
                    while start < samples.count {
                        let end = min(start + Self.feedSliceSamples, samples.count)
                        diarizer.appendAudio(Array(samples[start..<end]))
                        for result in try diarizer.processBufferedAudio() {
                            probabilities.append(contentsOf: result.probabilities)
                        }
                        start = end
                    }
                    for result in try diarizer.finishStream() {
                        probabilities.append(contentsOf: result.probabilities)
                    }
                    // `outputFrameSeconds` is a Float 0.01; widen without the
                    // float32 rounding error so turn times land on exact 10 ms steps.
                    let frameSeconds = (Double(config.outputFrameSeconds) * 1_000_000).rounded() / 1_000_000
                    continuation.resume(returning: NemotronFrameProbabilities(
                        probabilities: probabilities,
                        frameCount: speakers > 0 ? probabilities.count / speakers : 0,
                        numSpeakers: speakers,
                        frameSeconds: frameSeconds
                    ))
                } catch {
                    continuation.resume(throwing: error)
                }
            }
        }
    }
}
