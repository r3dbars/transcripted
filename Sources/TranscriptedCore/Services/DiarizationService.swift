// DiarizationService.swift
// Offline speaker diarization through FluidAudio. Two backends (`DiarizationBackend`):
//   - .pyannote (default): OfflineDiarizerManager, PyAnnote segmentation + WeSpeaker
//     + VBx clustering. Unlimited speakers, ~15% DER on VoxConverse via CoreML.
//   - .nemotron (experimental, opt-in): NVIDIA Nemotron 3 Diarization, up to 8
//     speakers at 10 ms resolution. Frame probabilities become exclusive turns via
//     `NemotronTurnBuilder`; voiceprints come from the injected segment embedder or
//     `FluidWeSpeakerSegmentEmbedder`, since Nemotron emits none.

import Foundation
@preconcurrency import FluidAudio

/// A speaker segment from diarization with optional voice fingerprint
public struct SpeakerSegment: Sendable {
    public let speakerId: Int          // Unlimited speakers from PyAnnote offline diarization
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

    /// Which diarization model this service runs. Fixed for the service's lifetime.
    public nonisolated let backend: DiarizationBackend

    // Offline pipeline (PyAnnote) — for post-recording transcripts
    private var offlineDiarizerManager: OfflineDiarizerManager?
    private var offlineInitializationTask: Task<Void, Never>?

    // Nemotron backend. The runner owns the non-thread-safe Nemotron3Diarizer.
    // The fallback embedder is loaded only when no `segmentEmbedder` was injected,
    // because Nemotron produces no voiceprints of its own.
    private var nemotronRunner: NemotronDiarizationRunner?
    private var nemotronFallbackEmbedder: FluidWeSpeakerSegmentEmbedder?

    /// Provider that resolves bundled model directories. Embedders can swap this to
    /// redirect lookups (e.g. a shared cache in Application Support). Returning `nil`
    /// from the provider falls through to HuggingFace download via `ModelDownloadService`.
    private let bundleProvider: ModelBundleProvider

    /// Optional override that re-derives each diarized segment's speaker embedding
    /// with a different model (e.g. ERes2Net) after diarization. When nil, the
    /// diarizer's native WeSpeaker embedding is used unchanged. `nonisolated` so the
    /// off-main-actor `diarizeOffline` path can read it without an actor hop.
    private nonisolated let segmentEmbedder: (any SpeakerSegmentEmbedder)?

    /// - Parameter backend: which diarization model to run. `.nemotron` also reads
    ///   the lab-only `TRANSCRIPTED_NEMOTRON_PRESET` environment override when it
    ///   initializes (see `NemotronDiarizationRunner.presetEnvironmentKey`).
    public init(
        bundleProvider: @escaping ModelBundleProvider = defaultModelBundleProvider,
        segmentEmbedder: (any SpeakerSegmentEmbedder)? = nil,
        backend: DiarizationBackend = .pyannote
    ) {
        self.bundleProvider = bundleProvider
        self.segmentEmbedder = segmentEmbedder
        self.backend = backend
    }

    /// Cosine thresholds for the active embedding model: the injected embedder's
    /// calibrated set, or the WeSpeaker defaults when the diarizer's native
    /// embedding is in use. The Nemotron backend's fallback embedder
    /// (`FluidWeSpeakerSegmentEmbedder`) is WeSpeaker too, so the default holds
    /// there as well. `nonisolated` so the off-main-actor pipeline reads it
    /// without an actor hop.
    public nonisolated var activeSpeakerThresholds: SpeakerEmbeddingThresholds {
        segmentEmbedder?.thresholds ?? .weSpeaker
    }

    public var isReady: Bool { modelState == .ready && backendModelsLoaded }

    /// Whether the active backend's models are in memory.
    private var backendModelsLoaded: Bool {
        switch backend {
        case .pyannote:
            return offlineDiarizerManager != nil
        case .nemotron:
            return nemotronRunner != nil && (segmentEmbedder != nil || nemotronFallbackEmbedder != nil)
        }
    }

    // MARK: - Model Initialization

    /// Load the offline diarization models required by the current meeting pipeline.
    public func initialize() async {
        guard !backendModelsLoaded else {
            modelState = .ready
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
            switch backend {
            case .pyannote:
                try await initializeOffline()
            case .nemotron:
                try await initializeNemotron()
            }

            modelState = .ready
            AppLogger.transcription.info("Offline diarization models loaded and ready")
        } catch {
            let kind = ModelDownloadService.classifyError(error)
            modelState = .failed(kind.detail)
            AppLogger.transcription.error("Offline diarization model initialization failed", ["error": "\(error.localizedDescription)", "kind": kind.title])
        }
    }

    /// The grid-searched cosine-similarity threshold (0.6) expressed as the Euclidean
    /// cut distance FluidAudio 0.17+ expects: sqrt(2 - 2 * 0.6).
    nonisolated static let tunedClusteringDistanceThreshold: Double = (2.0 - 2.0 * 0.6).squareRoot()

    /// Load PyAnnote offline diarization models from the app bundle or download.
    private func initializeOffline() async throws {
        let loadStart = Date()

        // Optimized config from DER grid search (v2, 100 iterations across 16 Zoom meetings).
        // Key win: Fa 0.07→0.25 (~halves DER by letting VBx reconsider speaker assignments).
        //
        // FluidAudio 0.17 changed two things under this tuned config, so both are
        // pinned to keep the 0.15.x behavior the grid search was run against:
        // - `clusteringThreshold` is now a Euclidean cut distance on unit-normalized
        //   embeddings, applied directly. 0.15.x read it as a cosine similarity and
        //   converted it with sqrt(2 - 2s), so the tuned 0.6 becomes sqrt(0.8).
        // - `clustering.constrainedAssignment` (pyannote parity) now defaults to true;
        //   0.15.x assigned each local speaker to its nearest centroid independently.
        var offlineConfig = OfflineDiarizerConfig(
            clusteringThreshold: Self.tunedClusteringDistanceThreshold,
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
        offlineConfig.clustering.constrainedAssignment = false
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
        let elapsed = String(format: "%.1fs", Date().timeIntervalSince(loadStart))
        AppLogger.transcription.info("Offline diarizer models loaded", ["elapsed": elapsed])
    }

    /// Load the Nemotron preset and, when no embedder was injected, the WeSpeaker
    /// fallback embedder. Both must load for the backend to report ready: without
    /// voiceprints the pipeline cannot give speakers persistent identities.
    private func initializeNemotron() async throws {
        let loadStart = Date()
        let presetName = NemotronDiarizationRunner.resolvePresetName()
        AppLogger.transcription.info("Nemotron diarizer initializing", [
            "backend": backend.rawValue, "preset": presetName
        ])

        let runner = try await NemotronDiarizationRunner.load(presetName: presetName, bundleProvider: bundleProvider)

        var fallbackEmbedder: FluidWeSpeakerSegmentEmbedder?
        if segmentEmbedder == nil {
            if let bundleDirectory = bundleProvider(FluidWeSpeakerSegmentEmbedder.bundleDirectoryName) {
                fallbackEmbedder = try await FluidWeSpeakerSegmentEmbedder.load(bundleDirectory: bundleDirectory)
            } else {
                fallbackEmbedder = try await ModelDownloadService.withRetry {
                    try await FluidWeSpeakerSegmentEmbedder.load(bundleDirectory: nil)
                }
            }
        }

        nemotronRunner = runner
        nemotronFallbackEmbedder = fallbackEmbedder
        let elapsed = String(format: "%.1fs", Date().timeIntervalSince(loadStart))
        AppLogger.transcription.info("Nemotron diarizer models loaded", [
            "backend": backend.rawValue,
            "preset": presetName,
            "embedder": segmentEmbedder?.identifier ?? FluidWeSpeakerSegmentEmbedder.embedderIdentifier,
            "elapsed": elapsed
        ])
    }

    // MARK: - Offline Diarization (PyAnnote)

    /// Run offline speaker diarization on audio samples using PyAnnote pipeline.
    /// Supports unlimited speakers. Samples should be 16kHz mono Float32.
    nonisolated public func diarizeOffline(samples: [Float], sampleRate: Int = 16000) async throws -> [SpeakerSegment] {
        if backend == .nemotron {
            return try await diarizeWithNemotron(samples: samples, sampleRate: sampleRate)
        }

        guard let manager = await MainActor.run(body: { self.offlineDiarizerManager }) else {
            throw NSError(domain: "DiarizationService", code: 2, userInfo: [
                NSLocalizedDescriptionKey: "Offline diarizer model not loaded"
            ])
        }

        AppLogger.transcription.info("Offline diarization starting", ["samples": "\(samples.count)", "duration": "\(String(format: "%.1f", Double(samples.count) / Double(sampleRate)))s"])

        let result = try await {
            do {
                return try await manager.process(audio: samples)
            } catch where Self.isVendorNoSpeechResult(error) {
                throw DiarizationResultError.noSpeechDetected
            }
        }()

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

    nonisolated static func isVendorNoSpeechResult(_ error: Error) -> Bool {
        let message = error.localizedDescription
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
        return message == "no speech detected"
            || message == "no speech detected in audio"
            || message == "no speech detected in the audio."
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
        guard let embedder = segmentEmbedder else { return segments }
        return reembed(segments: segments, samples: samples, sampleRate: sampleRate, using: embedder)
    }

    /// Replace each segment's embedding with `embedder`'s vector for the segment's
    /// audio slice. The body of `reembedIfNeeded`, shared with the Nemotron path,
    /// which always embeds (its turns arrive with no embedding at all).
    nonisolated func reembed(
        segments: [SpeakerSegment],
        samples: [Float],
        sampleRate: Int,
        using embedder: any SpeakerSegmentEmbedder
    ) -> [SpeakerSegment] {
        guard !segments.isEmpty else { return segments }
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

    // MARK: - Nemotron Diarization

    /// Nemotron path of `diarizeOffline(samples:sampleRate:)`: frame probabilities
    /// → exclusive turns (`NemotronTurnBuilder`) → one voiceprint per turn.
    private nonisolated func diarizeWithNemotron(samples: [Float], sampleRate: Int) async throws -> [SpeakerSegment] {
        let loadedRunner = await MainActor.run(body: { self.nemotronRunner })
        let activeEmbedder: (any SpeakerSegmentEmbedder)?
        if let injected = segmentEmbedder {
            activeEmbedder = injected
        } else {
            activeEmbedder = await MainActor.run(body: { self.nemotronFallbackEmbedder })
        }
        guard let runner = loadedRunner, let embedder = activeEmbedder else {
            throw NSError(domain: "DiarizationService", code: 2, userInfo: [
                NSLocalizedDescriptionKey: "Offline diarizer model not loaded"
            ])
        }
        guard sampleRate > 0 else {
            throw NSError(domain: "DiarizationService", code: 3, userInfo: [
                NSLocalizedDescriptionKey: "Invalid diarization sample rate"
            ])
        }

        // Nemotron's mel frontend is fixed at 16 kHz.
        let modelSampleRate = 16000
        let audio = sampleRate == modelSampleRate
            ? samples
            : AudioResampler.resample(samples, from: Double(sampleRate), to: Double(modelSampleRate))
        guard !audio.isEmpty else { throw DiarizationResultError.noSpeechDetected }

        AppLogger.transcription.info("Offline diarization starting", [
            "backend": backend.rawValue,
            "preset": runner.presetName,
            "samples": "\(audio.count)",
            "duration": "\(String(format: "%.1f", Double(audio.count) / Double(modelSampleRate)))s"
        ])
        let started = Date()

        let frames = try await runner.run(samples: audio)
        try Task.checkCancellation()
        let inferenceElapsed = Date().timeIntervalSince(started)

        let turns = NemotronTurnBuilder.turns(
            probabilities: frames.probabilities,
            frameCount: frames.frameCount,
            numSpeakers: frames.numSpeakers,
            frameSeconds: frames.frameSeconds
        )
        guard !turns.isEmpty else {
            AppLogger.transcription.info("Nemotron diarization found no speech", [
                "backend": backend.rawValue, "frames": "\(frames.frameCount)"
            ])
            throw DiarizationResultError.noSpeechDetected
        }

        // speakerId is 1-based to match the pyannote backend's "S1", "S2", ... ids.
        // Quality is the turn's mean winning probability (>= the 0.5 activity
        // threshold by construction), so the pipeline's < 0.3 quality gate never
        // discards a Nemotron turn on its own; its < 1 s duration gate still does.
        let segments = turns.map { turn in
            SpeakerSegment(
                speakerId: turn.speakerIndex + 1,
                startTime: turn.startTime,
                endTime: turn.endTime,
                embedding: nil,
                qualityScore: min(max(turn.meanActiveProbability, 0), 1)
            )
        }
        let finalSegments = reembed(segments: segments, samples: audio, sampleRate: modelSampleRate, using: embedder)

        let speakerIds = Set(finalSegments.map { $0.speakerId })
        AppLogger.transcription.info("Offline diarization complete", [
            "backend": backend.rawValue,
            "preset": runner.presetName,
            "segments": "\(finalSegments.count)",
            "speakers": "\(speakerIds.count)",
            "inference": String(format: "%.1fs", inferenceElapsed),
            "elapsed": String(format: "%.1fs", Date().timeIntervalSince(started))
        ])
        logSpeakerSummaries(finalSegments)

        return finalSegments
    }

    // MARK: - Cleanup

    public func cleanup() {
        offlineDiarizerManager = nil
        nemotronRunner = nil
        nemotronFallbackEmbedder = nil
        modelState = .notLoaded
    }

    // MARK: - Helpers

    /// Log per-speaker segment summaries from the offline pipeline.
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
        // Preserve compatibility with persisted/vendor IDs such as "speaker_0".
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

// MARK: - DiarizationEngine conformance
// Empty extension — protocol signatures match DiarizationService's existing methods exactly.

extension DiarizationService: DiarizationEngine {}
