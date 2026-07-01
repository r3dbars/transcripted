// DiarizationService.swift
// Dual-pipeline speaker diarization using FluidAudio.
//
// Streaming (Sortformer): Real-time diarization for live preview (future use,
// optional during app warmup).
//   - DiarizerManager, T×4 output matrix, up to 4 speakers.
//
// Offline (PyAnnote): Post-recording diarization for final transcripts.
//   - OfflineDiarizerManager, PyAnnote segmentation + WeSpeaker + VBx clustering.
//   - Unlimited speakers, ~15% DER on VoxConverse via CoreML.
//
// Both pipelines produce identical 256-dim WeSpeaker embeddings,
// so the entire speaker identification stack works unchanged.

import Foundation
@preconcurrency import FluidAudio

/// A speaker segment from diarization with optional voice fingerprint
public struct SpeakerSegment: Sendable {
    public let speakerId: Int          // Unlimited speakers (PyAnnote offline) or 0-3 (Sortformer streaming)
    public let startTime: Double       // seconds
    public let endTime: Double         // seconds
    public let embedding: [Float]?     // 256-dim voice fingerprint (from WeSpeaker)
    public let qualityScore: Float     // Segment quality (0-1)

    public init(speakerId: Int, startTime: Double, endTime: Double, embedding: [Float]?, qualityScore: Float) {
        self.speakerId = speakerId
        self.startTime = startTime
        self.endTime = endTime
        self.embedding = embedding
        self.qualityScore = qualityScore
    }

    public var duration: Double { endTime - startTime }
}

public enum DiarizationModelState: Equatable {
    case notLoaded
    case loading
    case ready
    case failed(String)
}

@available(macOS 14.0, *)
@MainActor
public class DiarizationService: ObservableObject {
    @Published public var modelState: DiarizationModelState = .notLoaded

    // Streaming pipeline (Sortformer) — for future real-time preview
    private var diarizerManager: DiarizerManager?

    // Offline pipeline (PyAnnote) — for post-recording transcripts
    private var offlineDiarizerManager: OfflineDiarizerManager?
    private var offlineModelState: DiarizationModelState = .notLoaded
    private var optionalStreamingWarmupTask: Task<Void, Never>?
    private var offlineInitializationTask: Task<Void, Never>?

    /// Provider that resolves bundled model directories. Embedders can swap this to
    /// redirect lookups (e.g. a shared cache in Application Support). Returning `nil`
    /// from the provider falls through to HuggingFace download via `ModelDownloadService`.
    private let bundleProvider: ModelBundleProvider

    /// Optional override that re-derives each diarized segment's speaker embedding
    /// with a different model (e.g. ERes2Net) after diarization. When nil, the
    /// diarizer's native WeSpeaker embedding is used unchanged. `nonisolated` so the
    /// off-main-actor `diarizeOffline` path can read it without an actor hop.
    private nonisolated let segmentEmbedder: (any SpeakerSegmentEmbedder)?

    public init(
        bundleProvider: @escaping ModelBundleProvider = defaultModelBundleProvider,
        segmentEmbedder: (any SpeakerSegmentEmbedder)? = nil
    ) {
        self.bundleProvider = bundleProvider
        self.segmentEmbedder = segmentEmbedder
    }

    /// Cosine thresholds for the active embedding model: the injected embedder's
    /// calibrated set, or the WeSpeaker defaults when the diarizer's native
    /// embedding is in use. `nonisolated` so the off-main-actor pipeline reads it
    /// without an actor hop.
    public nonisolated var activeSpeakerThresholds: SpeakerEmbeddingThresholds {
        segmentEmbedder?.thresholds ?? .weSpeaker
    }

    public var isReady: Bool { modelState == .ready && offlineDiarizerManager != nil }

    // MARK: - Model Initialization

    /// Load the offline diarization models required by the current meeting pipeline.
    /// Sortformer streaming is optional because no production meeting flow calls it yet.
    public func initialize() async {
        guard offlineDiarizerManager == nil else {
            modelState = .ready
            startOptionalStreamingWarmupIfAvailable()
            AppLogger.transcription.debug("Offline diarization already initialized")
            return
        }

        // Deduplicate concurrent loads. Warmup and queued-job recovery can
        // both call initialize(); without dedup they interleave at the await,
        // double-load the models, and a losing duplicate that throws would
        // overwrite modelState to .failed even though the first load
        // succeeded.
        if let inFlight = offlineInitializationTask {
            AppLogger.transcription.debug("Awaiting in-flight offline diarization initialization")
            await inFlight.value
            return
        }

        let task = Task {
            await self.performOfflineInitialization()
            self.offlineInitializationTask = nil
        }
        offlineInitializationTask = task
        await task.value
    }

    private func performOfflineInitialization() async {
        modelState = .loading
        AppLogger.transcription.info("Diarization initializing offline models")

        do {
            try await initializeOffline()

            modelState = .ready
            startOptionalStreamingWarmupIfAvailable()
            AppLogger.transcription.info("Offline diarization models loaded and ready")
        } catch {
            let kind = ModelDownloadService.classifyError(error)
            modelState = .failed(kind.detail)
            AppLogger.transcription.error("Offline diarization model initialization failed", ["error": "\(error.localizedDescription)", "kind": kind.title])
        }
    }

    /// Load Sortformer streaming models from the app bundle or download from HuggingFace.
    private func initializeStreaming(allowDownload: Bool = true) async throws {
        let loadStart = Date()
        let manager = DiarizerManager(config: .default)

        if let bundlePath = bundleProvider("sortformer-models") {
            AppLogger.transcription.info("Sortformer loading from bundle", ["path": "\(bundlePath)"])
            let models = try await DiarizerModels.load(from: bundlePath)
            manager.initialize(models: models)
        } else if allowDownload {
            AppLogger.transcription.info("Sortformer models not bundled, loading from cache or downloading")
            let models = try await ModelDownloadService.withRetry {
                try await DiarizerModels.download()
            }
            manager.initialize(models: models)
        } else {
            throw NSError(domain: "DiarizationService", code: 3, userInfo: [
                NSLocalizedDescriptionKey: "Sortformer streaming models are not bundled"
            ])
        }

        diarizerManager = manager
        let elapsed = String(format: "%.1fs", Date().timeIntervalSince(loadStart))
        AppLogger.transcription.info("Sortformer streaming models loaded", ["elapsed": elapsed])
    }

    /// Load PyAnnote offline diarization models from the app bundle or download.
    private func initializeOffline() async throws {
        offlineModelState = .loading
        let loadStart = Date()

        // Optimized config from DER grid search (v2, 100 iterations across 16 Zoom meetings).
        // Key win: Fa 0.07→0.25 (~halves DER by letting VBx reconsider speaker assignments).
        let offlineConfig = OfflineDiarizerConfig(
            clusteringThreshold: 0.6,
            Fa: 0.25,
            Fb: 0.63,
            windowDuration: 10.0,
            segmentationStepRatio: 0.266,
            embeddingBatchSize: 32,
            embeddingExcludeOverlap: true,
            minSegmentDuration: 1.1821,
            minGapDuration: 0.2874,
            speechOnsetThreshold: 0.4472,
            speechOffsetThreshold: 0.4472,
            segmentationMinDurationOn: 0.0,
            segmentationMinDurationOff: 0.2738,
            maxVBxIterations: 24,
            convergenceTolerance: 0.0001
        )
        let manager = OfflineDiarizerManager(config: offlineConfig)

        if let bundlePath = bundleProvider("offline-diarizer-models") {
            AppLogger.transcription.info("Offline diarizer loading from bundle", ["path": "\(bundlePath)"])
            let models = try await OfflineDiarizerModels.load(from: bundlePath)
            manager.initialize(models: models)
        } else {
            AppLogger.transcription.info("Offline diarizer models not bundled, loading from cache or downloading")
            try await ModelDownloadService.withRetry {
                try await manager.prepareModels()
            }
        }

        offlineDiarizerManager = manager
        offlineModelState = .ready
        let elapsed = String(format: "%.1fs", Date().timeIntervalSince(loadStart))
        AppLogger.transcription.info("Offline diarizer models loaded", ["elapsed": elapsed])
    }

    // MARK: - Offline Diarization (PyAnnote)

    /// Run offline speaker diarization on audio samples using PyAnnote pipeline.
    /// Supports unlimited speakers. Samples should be 16kHz mono Float32.
    nonisolated public func diarizeOffline(samples: [Float], sampleRate: Int = 16000) async throws -> [SpeakerSegment] {
        guard let manager = await MainActor.run(body: { self.offlineDiarizerManager }) else {
            throw NSError(domain: "DiarizationService", code: 2, userInfo: [
                NSLocalizedDescriptionKey: "Offline diarizer model not loaded"
            ])
        }

        AppLogger.transcription.info("Offline diarization starting", ["samples": "\(samples.count)", "duration": "\(String(format: "%.1f", Double(samples.count) / Double(sampleRate)))s"])

        let result = try await manager.process(audio: samples)

        // Copy FluidAudio/CoreML-backed outputs into plain Swift values before
        // result cleanup can recycle CoreML feature buffers on another queue.
        let segments = withExtendedLifetime(result) {
            result.segments.map { segment in
                let embedding = segment.embedding
                return SpeakerSegment(
                    speakerId: speakerIdFromString(segment.speakerId),
                    startTime: Double(segment.startTimeSeconds),
                    endTime: Double(segment.endTimeSeconds),
                    embedding: embedding.isEmpty ? nil : embedding.map { $0 },
                    qualityScore: segment.qualityScore
                )
            }
        }

        let finalSegments = reembedIfNeeded(segments: segments, samples: samples, sampleRate: sampleRate)

        let speakerIds = Set(finalSegments.map { $0.speakerId })
        AppLogger.transcription.info("Offline diarization complete", ["segments": "\(finalSegments.count)", "speakers": "\(speakerIds.count)"])
        logSpeakerSummaries(finalSegments)

        return finalSegments
    }

    /// Re-derive each segment's embedding with `segmentEmbedder` when present.
    /// Slices the original 16 kHz samples by segment time and replaces the
    /// embedding; segments where re-embedding fails are kept for diarization but
    /// lose their native vector so model-specific speaker databases do not mix
    /// embedding dimensions.
    /// No-op (returns input untouched) when no embedder is injected.
    /// `internal` (not `private`) so unit tests can exercise the bounds/slicing
    /// logic directly with a stub embedder, without standing up the real diarizer.
    nonisolated func reembedIfNeeded(segments: [SpeakerSegment], samples: [Float], sampleRate: Int) -> [SpeakerSegment] {
        guard let embedder = segmentEmbedder, !segments.isEmpty else { return segments }
        let total = samples.count
        var replaced = 0
        func withoutEmbedding(_ segment: SpeakerSegment) -> SpeakerSegment {
            SpeakerSegment(
                speakerId: segment.speakerId,
                startTime: segment.startTime,
                endTime: segment.endTime,
                embedding: nil,
                qualityScore: segment.qualityScore
            )
        }
        let result = segments.map { segment -> SpeakerSegment in
            let a = max(0, Int(segment.startTime * Double(sampleRate)))
            let b = min(total, Int(segment.endTime * Double(sampleRate)))
            guard b > a else { return withoutEmbedding(segment) }
            let slice = Array(samples[a..<b])
            guard let emb = embedder.embed(samples: slice, sampleRate: sampleRate) else {
                return withoutEmbedding(segment)
            }
            replaced += 1
            return SpeakerSegment(
                speakerId: segment.speakerId,
                startTime: segment.startTime,
                endTime: segment.endTime,
                embedding: emb,
                qualityScore: segment.qualityScore
            )
        }
        AppLogger.transcription.info("Re-embedded segments with \(embedder.identifier)", [
            "replaced": "\(replaced)", "total": "\(segments.count)", "dim": "\(embedder.dimension)"
        ])
        return result
    }

    /// Run offline speaker diarization on a WAV file.
    nonisolated public func diarizeOffline(audioURL: URL) async throws -> [SpeakerSegment] {
        let samples = try AudioResampler.loadAndResample(url: audioURL, targetRate: 16000)
        return try await diarizeOffline(samples: samples, sampleRate: 16000)
    }

    // MARK: - Streaming Diarization (Sortformer)

    /// Run streaming speaker diarization on audio samples using Sortformer.
    /// Limited to 4 speakers. Samples should be 16kHz mono Float32.
    nonisolated public func diarizeStreaming(samples: [Float], sampleRate: Int = 16000) async throws -> [SpeakerSegment] {
        guard let manager = await MainActor.run(body: { self.diarizerManager }),
              manager.isAvailable else {
            throw NSError(domain: "DiarizationService", code: 1, userInfo: [
                NSLocalizedDescriptionKey: "Sortformer model not loaded"
            ])
        }

        AppLogger.transcription.info("Sortformer diarizing", ["samples": "\(samples.count)", "duration": "\(String(format: "%.1f", Double(samples.count) / Double(sampleRate)))s"])

        let result = try manager.performCompleteDiarization(samples, sampleRate: sampleRate)

        let segments = withExtendedLifetime(result) {
            result.segments.map { segment in
                let embedding = segment.embedding
                return SpeakerSegment(
                    speakerId: speakerIdFromString(segment.speakerId),
                    startTime: Double(segment.startTimeSeconds),
                    endTime: Double(segment.endTimeSeconds),
                    embedding: embedding.isEmpty ? nil : embedding.map { $0 },
                    qualityScore: segment.qualityScore
                )
            }
        }

        let speakerIds = Set(segments.map { $0.speakerId })
        AppLogger.transcription.info("Sortformer diarization complete", ["segments": "\(segments.count)", "speakers": "\(speakerIds.count)"])
        logSpeakerSummaries(segments)

        return segments
    }

    /// Run streaming speaker diarization on a WAV file.
    nonisolated public func diarizeStreaming(audioURL: URL) async throws -> [SpeakerSegment] {
        let samples = try AudioResampler.loadAndResample(url: audioURL, targetRate: 16000)
        return try await diarizeStreaming(samples: samples, sampleRate: 16000)
    }

    // MARK: - Cleanup

    public func cleanup() {
        optionalStreamingWarmupTask?.cancel()
        optionalStreamingWarmupTask = nil
        diarizerManager = nil
        offlineDiarizerManager = nil
        modelState = .notLoaded
        offlineModelState = .notLoaded
    }

    // MARK: - Helpers

    /// Log per-speaker segment summaries (shared by offline and streaming pipelines).
    private nonisolated func logSpeakerSummaries(_ segments: [SpeakerSegment]) {
        var summaries: [Int: (count: Int, duration: Double)] = [:]
        for segment in segments {
            let current = summaries[segment.speakerId] ?? (count: 0, duration: 0)
            summaries[segment.speakerId] = (
                count: current.count + 1,
                duration: current.duration + segment.duration
            )
        }

        for id in summaries.keys.sorted() {
            guard let summary = summaries[id] else { continue }
            AppLogger.transcription.debug("Speaker \(id): \(summary.count) segments, \(String(format: "%.1f", summary.duration))s")
        }
    }

    /// Convert FluidAudio's string speaker ID (e.g., "speaker_0") to integer
    nonisolated func speakerIdFromString(_ id: String) -> Int {
        // Sortformer uses "speaker_0", "speaker_1", etc.
        if let separator = id.lastIndex(of: "_"),
           let intId = Int(id[id.index(after: separator)...]) {
            return intId
        }
        // PyAnnote offline uses "S0", "S1", "S2", etc.
        if id.hasPrefix("S"), let intId = Int(id.dropFirst()) {
            return intId
        }
        // Fallback: try direct Int parsing
        if let directId = Int(id) {
            return directId
        }
        AppLogger.transcription.error("speakerIdFromString failed to parse speaker ID, falling back to 0", ["raw_id": id])
        return 0
    }
}

@available(macOS 14.0, *)
private extension DiarizationService {
    func startOptionalStreamingWarmupIfAvailable() {
        guard diarizerManager == nil, optionalStreamingWarmupTask == nil else { return }
        guard bundleProvider("sortformer-models") != nil else {
            AppLogger.transcription.debug("Sortformer streaming models not bundled; skipping optional warmup")
            return
        }

        optionalStreamingWarmupTask = Task { @MainActor [weak self] in
            guard let self else { return }
            defer { self.optionalStreamingWarmupTask = nil }

            do {
                try await self.initializeStreaming(allowDownload: false)
            } catch {
                AppLogger.transcription.warning("Optional Sortformer streaming warmup skipped", [
                    "error": error.localizedDescription
                ])
            }
        }
    }
}

// MARK: - DiarizationEngine conformance
// Empty extension — protocol signatures match DiarizationService's existing methods exactly.
// Added as part of Step 8 protocol wiring (merge-plan §5.1).

extension DiarizationService: DiarizationEngine {}
