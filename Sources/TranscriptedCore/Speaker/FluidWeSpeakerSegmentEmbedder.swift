// FluidWeSpeakerSegmentEmbedder.swift
// A 256-d WeSpeaker voiceprint per segment, for diarizers that emit none.
//
// Nemotron 3 Diarization only says "who spoke when"; it produces no speaker
// embeddings. The meeting pipeline's identity stack (same-voice consolidation,
// cross-call matching, naming) needs one per segment, so when the host did not
// inject a `SpeakerSegmentEmbedder` the Nemotron backend falls back to this one.
// It runs FluidAudio's *online* diarizer embedding model through the public
// `DiarizerManager.extractSpeakerEmbedding(from:)` API.
//
// Compatibility with today's speaker database (read before trusting cross-call
// matches):
//
// - Both this model and the offline pyannote pipeline's embedding model come from
//   the same Hugging Face repo, `FluidInference/speaker-diarization-coreml`
//   (`Repo.diarizer`), and FluidAudio's docs describe both as WeSpeaker, with
//   "both offline and online versions use the community-1 model" (Benchmarks.md).
//   pyannote 3.1 and community-1 both use the WeSpeaker ResNet34 (VoxCeleb)
//   speaker embedding, so this is very likely the same network and training.
// - They are NOT the same Core ML artifact. The online model is
//   `wespeaker_v2.mlmodelc`: raw 16 kHz waveform + frame mask in, fbank computed
//   inside the graph, a 3-slot batch of 10 s windows. The offline model is
//   `Embedding.mlmodelc`, fed log-mel fbank from a separate CPU-pinned
//   `FBank.mlmodelc` plus per-frame weights. Two different conversions (and fp16
//   paths) of the same weights give close but not bit-identical vectors, and
//   nothing in FluidAudio 0.17.0 checks their parity.
// - The vectors in today's database are also a different *kind* of thing: the
//   pyannote backend's per-segment embedding is the VBx cluster centroid (a
//   weighted mean of raw, un-normalized 10 s-window embeddings with overlapped
//   frames excluded). This embedder returns one L2-normalized vector per turn.
//
// So: same 256-d space in principle and the `.weSpeaker` thresholds are the right
// starting point, but cross-meeting matching against people saved by the pyannote
// backend is unverified. Measure it (same clips through both paths, cosine) before
// letting this write into the default `speakers.sqlite`. Its `identifier` is
// distinct so a host that injects it explicitly gets its own database.

import Foundation
@preconcurrency import FluidAudio

@available(macOS 14.0, *)
public final class FluidWeSpeakerSegmentEmbedder: SpeakerSegmentEmbedder, @unchecked Sendable {

    /// Stable identifier for this model/path; namespaces a host-side speaker DB.
    public static let embedderIdentifier = "wespeaker-fluid-online"

    /// `ModelBundleProvider` key for a bundled copy of the online diarizer models
    /// (`pyannote_segmentation.mlmodelc` + `wespeaker_v2.mlmodelc` side by side).
    /// The segmentation model is required too: FluidAudio reads its output shape to
    /// size the embedding mask.
    public static let bundleDirectoryName = "online-diarizer-models"

    public let dimension = 256
    public let identifier = FluidWeSpeakerSegmentEmbedder.embedderIdentifier
    public let thresholds = SpeakerEmbeddingThresholds.weSpeaker

    /// The model's fixed input window: 10 s at 16 kHz. Longer clips are split.
    static let windowSamples = 160_000
    /// Shorter clips return nil. The model repeat-pads short input to 10 s, which
    /// is fine for real speech but meaningless for a few frames of audio.
    static let minSamples = 4_000          // 0.25 s
    /// A trailing window shorter than this is skipped when earlier full windows
    /// already cover the clip (a 0.3 s tail would be tiled 30x and skew the mean).
    static let minTailSamples = 16_000     // 1 s

    private let manager: DiarizerManager
    /// `DiarizerManager` is not thread-safe; serialize every call into it.
    private let lock = NSLock()

    init(manager: DiarizerManager) {
        self.manager = manager
    }

    /// Load the online diarizer models from `bundleDirectory` when given, else from
    /// FluidAudio's cache (downloading on first use into
    /// `~/Library/Application Support/FluidAudio/Models/speaker-diarization/`,
    /// the same folder the offline pyannote models use).
    public static func load(bundleDirectory: URL? = nil) async throws -> FluidWeSpeakerSegmentEmbedder {
        // Same repo as the pyannote models: keep markerless caches valid.
        FluidAudioCompatibility.keepUnpinnedDiarizerCaches()
        let models: DiarizerModels
        if let bundleDirectory {
            models = try DiarizerModels.load(
                localSegmentationModel: bundleDirectory.appendingPathComponent(ModelNames.Diarizer.segmentationFile),
                localEmbeddingModel: bundleDirectory.appendingPathComponent(ModelNames.Diarizer.embeddingFile)
            )
        } else {
            models = try await DiarizerModels.downloadIfNeeded()
        }
        let manager = DiarizerManager()
        manager.initialize(models: models)
        AppLogger.speakers.info("WeSpeaker segment embedder loaded", [
            "identifier": embedderIdentifier, "dim": "256"
        ])
        return FluidWeSpeakerSegmentEmbedder(manager: manager)
    }

    public func embed(samples: [Float], sampleRate: Int) -> [Float]? {
        guard sampleRate == 16000 else {
            AppLogger.speakers.error("WeSpeaker segment embedder requires 16kHz audio", ["got": "\(sampleRate)"])
            return nil
        }
        guard samples.count >= Self.minSamples else { return nil }

        let windows = Self.windowBounds(
            sampleCount: samples.count,
            windowSamples: Self.windowSamples,
            minTailSamples: Self.minTailSamples
        )
        var pooled: [[Float]] = []
        pooled.reserveCapacity(windows.count)

        lock.lock()
        defer { lock.unlock() }
        for window in windows {
            let clip = Array(samples[window])
            do {
                let raw = try manager.extractSpeakerEmbedding(from: clip)
                if let usable = Self.usableEmbedding(raw, dimension: dimension) {
                    pooled.append(usable)
                }
            } catch {
                AppLogger.speakers.error("WeSpeaker segment embedding failed", ["error": "\(error.localizedDescription)"])
            }
        }
        guard !pooled.isEmpty else { return nil }
        return pooled.count == 1 ? pooled[0] : ERes2NetEmbedder.meanPoolNormalized(pooled)
    }

    // MARK: - Pure helpers (unit-tested without the model)

    /// Consecutive `windowSamples`-long ranges covering `sampleCount` samples. A
    /// clip that fits one window is one range. A trailing partial window shorter
    /// than `minTailSamples` is dropped when at least one full window precedes it.
    static func windowBounds(sampleCount: Int, windowSamples: Int, minTailSamples: Int) -> [Range<Int>] {
        guard sampleCount > 0, windowSamples > 0 else { return [] }
        if sampleCount <= windowSamples { return [0..<sampleCount] }
        var out: [Range<Int>] = []
        var start = 0
        while start < sampleCount {
            let end = min(start + windowSamples, sampleCount)
            if end - start < minTailSamples, !out.isEmpty { break }
            out.append(start..<end)
            start = end
        }
        return out
    }

    /// Reject wrong-size, non-finite, or all-zero vectors (FluidAudio returns a
    /// zero vector when its extractor falls back); L2-normalize the rest.
    static func usableEmbedding(_ raw: [Float], dimension: Int) -> [Float]? {
        guard raw.count == dimension, raw.allSatisfy({ $0.isFinite }) else { return nil }
        let normalized = ERes2NetEmbedder.l2Normalize(raw)
        guard normalized.contains(where: { $0 != 0 }) else { return nil }
        return normalized
    }
}
