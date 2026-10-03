// DiarizationService.swift
// Offline speaker diarization through FluidAudio. Two backends (`DiarizationBackend`):
//   - .nemotron (the app's default): NVIDIA Nemotron 3 Diarization, up to 8
//     speakers at 10 ms resolution. Frame probabilities become exclusive turns via
//     `NemotronTurnBuilder`; voiceprints come from the injected segment embedder or
//     `FluidOfflineWeSpeakerSegmentEmbedder` (the pyannote path's own WeSpeaker
//     model), since Nemotron emits none. If Nemotron can't load, pyannote stands in.
//   - .pyannote: OfflineDiarizerManager, PyAnnote segmentation + WeSpeaker + VBx
//     clustering. Unlimited speakers, ~15% DER on VoxConverse via CoreML.

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

    /// Which diarization model this service was asked to run. Fixed for the service's lifetime.
    public nonisolated let backend: DiarizationBackend

    /// The model actually loaded: `backend`, unless Nemotron failed to load (offline
    /// on first use, a bad download) and pyannote stood in so meetings still get
    /// speakers. Reset by `cleanup()`, so the next initialize tries Nemotron again.
    /// Both paths embed with the same offline WeSpeaker model, so the speaker
    /// database stays the same either way.
    public private(set) var activeBackend: DiarizationBackend

    // Offline pipeline (PyAnnote) — for post-recording transcripts
    private var offlineDiarizerManager: OfflineDiarizerManager?
    private var offlineInitializationTask: Task<Void, Never>?

    // Nemotron backend. The runner owns the non-thread-safe Nemotron3Diarizer.
    // The fallback embedder is loaded only when no `segmentEmbedder` was injected,
    // because Nemotron produces no voiceprints of its own.
    private var nemotronRunner: NemotronDiarizationRunner?
    private var nemotronFallbackEmbedder: (any SpeakerSegmentEmbedder)?

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
        self.activeBackend = backend
        // Before any diarizer model loads: keep 0.15.x-era (and bundled) pyannote
        // caches valid under FluidAudio 0.17's pinned revision.
        FluidAudioCompatibility.keepUnpinnedDiarizerCaches()
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

    /// What the next `diarizeOffline` call runs: `activeBackend` (so a Nemotron
    /// load failure reads pyannote) and the model that embeds its turns — the
    /// injected embedder, else Nemotron's fallback embedder, else pyannote's
    /// native offline WeSpeaker.
    public var activeRunDescriptor: DiarizationRunDescriptor {
        let voiceprintModel: String?
        if let segmentEmbedder {
            voiceprintModel = segmentEmbedder.identifier
        } else {
            switch activeBackend {
            case .pyannote: voiceprintModel = FluidOfflineWeSpeakerSegmentEmbedder.embedderIdentifier
            case .nemotron: voiceprintModel = nemotronFallbackEmbedder?.identifier
            }
        }
        return DiarizationRunDescriptor(backend: activeBackend, voiceprintModel: voiceprintModel)
    }

    /// The Nemotron preset the `.nemotron` backend loads for `environment`: the lab-only
    /// `TRANSCRIPTED_NEMOTRON_PRESET` override when it names a known preset, otherwise the
    /// default (`fast128`). Unknown names fall back to the default, as `initialize()` does.
    /// Lets tools such as the speaker lab record the preset that actually ran.
    public nonisolated static func resolvedNemotronPresetName(
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) -> String {
        NemotronDiarizationRunner.resolvePresetName(environment: environment)
    }

    public var isReady: Bool { modelState == .ready && backendModelsLoaded }

    /// Whether the active backend's models are in memory.
    private var backendModelsLoaded: Bool {
        switch activeBackend {
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

        // A background-loaded voiceprint loads alongside the diarizer models, off
        // this actor, and the service only reports ready once it has settled.
        let embedderLoad: Task<Void, Never>? = (segmentEmbedder as? any BackgroundLoadingSpeakerSegmentEmbedder)
            .map { loading in Task.detached(priority: .utility) { _ = await loading.waitUntilLoaded() } }

        do {
            switch backend {
            case .pyannote:
                try await initializeOffline()
            case .nemotron:
                do {
                    try await initializeNemotron()
                    activeBackend = .nemotron
                } catch {
                    let kind = ModelDownloadService.classifyError(error)
                    AppLogger.transcription.warning("Nemotron diarizer failed to load; using pyannote", [
                        "error": "\(error.localizedDescription)", "kind": kind.title
                    ])
                    nemotronRunner = nil
                    nemotronFallbackEmbedder = nil
                    try await initializeOffline()
                    activeBackend = .pyannote
                }
            }

            await embedderLoad?.value
            modelState = .ready
            AppLogger.transcription.info("Offline diarization models loaded and ready")
        } catch {
            let kind = ModelDownloadService.classifyError(error)
            modelState = .failed(kind.detail)
            AppLogger.transcription.error("Offline diarization model initialization failed", ["error": "\(error.localizedDescription)", "kind": kind.title])
        }
    }

    /// Load PyAnnote offline diarization models from the app bundle or download.
    private func initializeOffline() async throws {
        let loadStart = Date()

        // Tuned config with FluidAudio 0.17's two clustering changes undone, plus the
        // hill-climb lab's LabKnobOverrides knobs; see
        // FluidAudioCompatibility.tunedOfflineDiarizerConfig().
        let offlineConfig = FluidAudioCompatibility.tunedOfflineDiarizerConfig()
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
        baseOfflineConfig = offlineConfig
        let elapsed = String(format: "%.1fs", Date().timeIntervalSince(loadStart))
        AppLogger.transcription.info("Offline diarizer models loaded", ["elapsed": elapsed])
    }

    /// Speaker-lab seam (Tools/SpeakerEvalHarness): bounds on how many speakers the
    /// offline diarizer may return. FluidAudio re-clusters to fit when the count it
    /// finds falls outside them. The lab sets this per meeting to test a speaker-count
    /// hint taken from the calendar invite; while set it applies to every offline
    /// call. The app never sets it.
    public var labSpeakerBounds: DiarizationSpeakerBounds?
    private var baseOfflineConfig: OfflineDiarizerConfig?

    /// A one-off manager with the loaded settings plus `bounds`, loading models the
    /// same way `initializeOffline` does (CoreML's compile cache keeps this quick).
    private func boundedManager(_ bounds: DiarizationSpeakerBounds) async throws -> OfflineDiarizerManager? {
        guard var config = baseOfflineConfig else { return nil }
        config.clustering.minSpeakers = bounds.min
        config.clustering.maxSpeakers = bounds.max
        let manager = OfflineDiarizerManager(config: config)
        if let bundlePath = bundleProvider("offline-diarizer-models") {
            manager.initialize(models: try await OfflineDiarizerModels.load(from: bundlePath))
        } else {
            try await manager.prepareModels()
        }
        return manager
    }

    /// Managers that differ from the loaded one only in clustering threshold
    /// (`SpeakerSeparationOptions.clusteringThreshold`). They share one copy of the
    /// models, loaded from the same place `initializeOffline` loads them.
    private var thresholdManagers: [Double: OfflineDiarizerManager] = [:]
    private var sharedOfflineModels: OfflineDiarizerModels?

    private func manager(clusteringThreshold: Double) async throws -> OfflineDiarizerManager? {
        if let cached = thresholdManagers[clusteringThreshold] { return cached }
        guard var config = baseOfflineConfig else { return nil }
        // Our threshold is a cosine similarity (0.15.x semantics); FluidAudio 0.17
        // reads a cut distance.
        config.clusteringThreshold = FluidAudioCompatibility.clusteringDistance(fromCosineSimilarity: clusteringThreshold)
        let models: OfflineDiarizerModels
        if let shared = sharedOfflineModels {
            models = shared
        } else {
            models = try await OfflineDiarizerModels.load(
                from: bundleProvider("offline-diarizer-models") ?? OfflineDiarizerModels.defaultModelsDirectory()
            )
            sharedOfflineModels = models
        }
        let manager = OfflineDiarizerManager(config: config)
        manager.initialize(models: models)
        thresholdManagers[clusteringThreshold] = manager
        AppLogger.transcription.info("Offline diarizer ready at a custom clustering threshold", [
            "threshold": String(format: "%.2f", clusteringThreshold)
        ])
        return manager
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

        // Voiceprints come from the same offline WeSpeaker model the pyannote backend
        // uses, so Nemotron turns match the people already in speakers.sqlite
        // (FluidOfflineWeSpeakerSegmentEmbedder). TRANSCRIPTED_NEMOTRON_EMBEDDER=online
        // (lab only) switches to #1789's online-model embedder for comparison.
        var fallbackEmbedder: (any SpeakerSegmentEmbedder)?
        if segmentEmbedder == nil {
            if ProcessInfo.processInfo.environment["TRANSCRIPTED_NEMOTRON_EMBEDDER"] == "online" {
                if let bundleDirectory = bundleProvider(FluidWeSpeakerSegmentEmbedder.bundleDirectoryName) {
                    fallbackEmbedder = try await FluidWeSpeakerSegmentEmbedder.load(bundleDirectory: bundleDirectory)
                } else {
                    fallbackEmbedder = try await ModelDownloadService.withRetry {
                        try await FluidWeSpeakerSegmentEmbedder.load(bundleDirectory: nil)
                    }
                }
            } else {
                let bundled = bundleProvider("offline-diarizer-models")
                fallbackEmbedder = try await ModelDownloadService.withRetry {
                    try await FluidOfflineWeSpeakerSegmentEmbedder.load(directory: bundled)
                }
            }
        }

        nemotronRunner = runner
        nemotronFallbackEmbedder = fallbackEmbedder
        let elapsed = String(format: "%.1fs", Date().timeIntervalSince(loadStart))
        AppLogger.transcription.info("Nemotron diarizer models loaded", [
            "backend": backend.rawValue,
            "preset": presetName,
            "embedder": segmentEmbedder?.identifier ?? fallbackEmbedder?.identifier ?? "none",
            "elapsed": elapsed
        ])
    }

    // MARK: - Offline Diarization (PyAnnote)

    /// Run offline speaker diarization on audio samples with the active backend.
    /// Supports unlimited speakers. Samples should be 16kHz mono Float32.
    nonisolated public func diarizeOffline(samples: [Float], sampleRate: Int = 16000) async throws -> [SpeakerSegment] {
        try await diarizeOffline(samples: samples, sampleRate: sampleRate, clusteringThreshold: nil)
    }

    /// Same as `diarizeOffline(samples:sampleRate:)`, at `clusteringThreshold` when
    /// it is set (a cosine similarity; higher splits more; nil keeps the shipped 0.6).
    /// The Nemotron backend has no clustering step, so it ignores the threshold.
    nonisolated public func diarizeOffline(
        samples: [Float],
        sampleRate: Int,
        clusteringThreshold: Double?
    ) async throws -> [SpeakerSegment] {
        // Start loading the voiceprint model now so it's warm for re-embedding
        // after a short diarization (it still idle-releases after 60 s).
        prewarmVoiceprintInBackground()
        if await MainActor.run(body: { self.activeBackend }) == .nemotron {
            return try await diarizeWithNemotron(samples: samples, sampleRate: sampleRate)
        }

        guard var manager = await MainActor.run(body: { self.offlineDiarizerManager }) else {
            throw NSError(domain: "DiarizationService", code: 2, userInfo: [
                NSLocalizedDescriptionKey: "Offline diarizer model not loaded"
            ])
        }
        if let clusteringThreshold, let custom = try await self.manager(clusteringThreshold: clusteringThreshold) {
            manager = custom
        }
        if let bounds = await MainActor.run(body: { self.labSpeakerBounds }),
           let bounded = try await self.boundedManager(bounds) {
            manager = bounded
        }

        AppLogger.transcription.info("Offline diarization starting", ["backend": DiarizationBackend.pyannote.rawValue, "samples": "\(samples.count)", "duration": "\(String(format: "%.1f", Double(samples.count) / Double(sampleRate)))s"])

        let diarizeStart = ProcessInfo.processInfo.systemUptime
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

        await waitForBackgroundSegmentEmbedder()
        if let embedder = segmentEmbedder {
            prewarmVoiceprintLengths(for: segments, sampleCount: samples.count, sampleRate: sampleRate, using: embedder)
        }
        let finalSegments = reembedIfNeeded(segments: segments, samples: samples, sampleRate: sampleRate)
        MeetingPipelineTimings.current?.add(
            .diarize,
            seconds: ProcessInfo.processInfo.systemUptime - diarizeStart
        )

        let speakerIds = Set(finalSegments.map { $0.speakerId })
        AppLogger.transcription.info("Offline diarization complete", ["segments": "\(finalSegments.count)", "speakers": "\(speakerIds.count)"])
        logSpeakerSummaries(finalSegments)

        return finalSegments
    }

    /// Reloads an idle-released injected voiceprint on a utility queue. A plain
    /// queue, not a task: the load blocks its thread for up to a second or so.
    /// Only the injected embedder releases while idle; the diarizer's own
    /// models stay loaded.
    nonisolated public func prewarmVoiceprintInBackground() {
        guard let embedder = segmentEmbedder else { return }
        DispatchQueue.global(qos: .utility).async { embedder.prewarm() }
    }

    /// Hands the turn lengths `reembed` is about to embed to an embedder that can
    /// warm up for them, on a background queue, and returns at once. Re-embedding
    /// starts right away; a call on a function still warming waits for it, then
    /// runs at steady speed. Never changes the vectors.
    nonisolated func prewarmVoiceprintLengths(
        for segments: [SpeakerSegment],
        sampleCount total: Int,
        sampleRate: Int,
        using embedder: any SpeakerSegmentEmbedder
    ) {
        guard let warming = embedder as? any SpeakerSegmentLengthPrewarming,
              !(embedder is any ContextualSpeakerSegmentEmbedder) else { return }
        let counts = segments.compactMap { segment -> Int? in
            let bounds = Self.sampleBounds(of: segment, sampleRate: sampleRate, total: total)
            return bounds.end > bounds.start ? bounds.end - bounds.start : nil
        }
        guard !counts.isEmpty else { return }
        DispatchQueue.global(qos: .userInitiated).async { warming.prewarm(sampleCounts: counts) }
    }

    /// The samples of a `total`-sample recording that `segment` covers, as
    /// `reembed` slices them (clamped to the recording; empty when end <= start).
    nonisolated static func sampleBounds(of segment: SpeakerSegment, sampleRate: Int, total: Int) -> (start: Int, end: Int) {
        (max(0, Int(segment.startTime * Double(sampleRate))), min(total, Int(segment.endTime * Double(sampleRate))))
    }

    nonisolated static func isVendorNoSpeechResult(_ error: Error) -> Bool {
        let message = error.localizedDescription
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
        return message == "no speech detected"
            || message == "no speech detected in audio"
            || message == "no speech detected in the audio."
    }

    /// Waits for a background-loaded `segmentEmbedder` to finish loading, so the
    /// re-embedding that follows never blocks a thread on the load. Returns at
    /// once for any other embedder, or once the load has ended.
    nonisolated func waitForBackgroundSegmentEmbedder() async {
        guard let loading = segmentEmbedder as? any BackgroundLoadingSpeakerSegmentEmbedder else { return }
        _ = await loading.waitUntilLoaded()
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
        // One pool per turn: whatever the embedder autoreleases (Core ML arrays) is
        // freed before the next turn, not when the whole meeting is done.
        let result = segments.map { segment -> SpeakerSegment in
            autoreleasepool { () -> SpeakerSegment in
                let (a, b) = Self.sampleBounds(of: segment, sampleRate: sampleRate, total: total)
                guard b > a else { return withoutEmbedding(segment) }
                let embedding: [Float]?
                if let contextual = embedder as? any ContextualSpeakerSegmentEmbedder {
                    embedding = contextual.embed(audio: samples, sampleRate: sampleRate, startSample: a, endSample: b)
                } else {
                    embedding = embedder.embed(samples: Array(samples[a..<b]), sampleRate: sampleRate)
                }
                guard let emb = embedding else {
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
            await waitForBackgroundSegmentEmbedder()
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
        prewarmVoiceprintLengths(for: segments, sampleCount: audio.count, sampleRate: modelSampleRate, using: embedder)
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
        thresholdManagers = [:]
        sharedOfflineModels = nil
        nemotronRunner = nil
        nemotronFallbackEmbedder = nil
        activeBackend = backend
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

/// Speaker-count bounds for `DiarizationService.labSpeakerBounds` (speaker lab only).
public struct DiarizationSpeakerBounds: Sendable, Equatable {
    public let min: Int?
    public let max: Int?

    public init(min: Int?, max: Int?) {
        self.min = min
        self.max = max
    }
}
