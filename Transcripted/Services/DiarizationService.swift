// DiarizationService.swift
// Dual-pipeline speaker diarization using FluidAudio.
//
// Streaming (Sortformer): Real-time diarization for live preview (future use).
//   - DiarizerManager, T×4 output matrix, up to 4 speakers.
//
// Offline (PyAnnote): Post-recording diarization for final transcripts.
//   - OfflineDiarizerManager, PyAnnote segmentation + WeSpeaker + VBx clustering.
//   - Unlimited speakers, ~15% DER on VoxConverse via CoreML.
//
// Both pipelines produce identical 256-dim WeSpeaker embeddings,
// so the entire speaker identification stack works unchanged.

import Foundation
import FluidAudio

/// A speaker segment from diarization with optional voice fingerprint
struct SpeakerSegment {
    let speakerId: Int          // Unlimited speakers (PyAnnote offline) or 0-3 (Sortformer streaming)
    let startTime: Double       // seconds
    let endTime: Double         // seconds
    let embedding: [Float]?     // 256-dim voice fingerprint (from WeSpeaker)
    let qualityScore: Float     // Segment quality (0-1)

    var duration: Double { endTime - startTime }
}

enum DiarizationModelState: Equatable {
    case notLoaded
    case loading
    case ready
    case failed(String)
}

@available(macOS 14.0, *)
@MainActor
class DiarizationService: ObservableObject {
    @Published var modelState: DiarizationModelState = .notLoaded

    // Streaming pipeline (Sortformer) — for future real-time preview
    private var diarizerManager: DiarizerManager?

    // Offline pipeline (PyAnnote) — for post-recording transcripts
    private var offlineDiarizerManager: OfflineDiarizerManager?
    private var offlineModelState: DiarizationModelState = .notLoaded

    var isReady: Bool {
        offlineDiarizerManager != nil || diarizerManager?.isAvailable ?? false
    }

    // MARK: - Model Initialization

    /// Load all diarization models (streaming + offline) from the app bundle or download.
    func initialize() async {
        guard diarizerManager == nil, offlineDiarizerManager == nil else {
            AppLogger.transcription.debug("Diarization already initialized")
            return
        }

        modelState = .loading
        AppLogger.transcription.info("Diarization initializing models")

        do {
            // Initialize streaming (Sortformer) pipeline
            try await initializeStreaming()

            // Initialize offline (PyAnnote) pipeline
            try await initializeOffline()

            modelState = .ready
            AppLogger.transcription.info("Diarization models loaded and ready")
        } catch {
            let kind = ModelDownloadService.classifyError(error)
            modelState = .failed(kind.detail)
            AppLogger.transcription.error("Diarization model initialization failed", ["error": "\(error.localizedDescription)", "kind": kind.title])
        }
    }

    /// Load Sortformer streaming models from the app bundle or download from HuggingFace.
    private func initializeStreaming() async throws {
        let loadStart = Date()
        let manager = DiarizerManager(config: .default)

        if let bundlePath = bundledModelsPath(directory: "sortformer-models") {
            AppLogger.transcription.info("Sortformer loading from bundle", ["path": "\(bundlePath)"])
            let models = try await DiarizerModels.load(from: bundlePath)
            manager.initialize(models: models)
        } else {
            AppLogger.transcription.info("Sortformer models not bundled, loading from cache or downloading")
            let models = try await ModelDownloadService.withRetry {
                try await DiarizerModels.download()
            }
            manager.initialize(models: models)
        }

        diarizerManager = manager
        let elapsed = String(format: "%.1fs", Date().timeIntervalSince(loadStart))
        AppLogger.transcription.info("Sortformer streaming models loaded", ["elapsed": elapsed])
    }

    /// Load PyAnnote offline diarization models from the app bundle or download.
    private func initializeOffline() async throws {
        offlineModelState = .loading
        let loadStart = Date()

        // Configure speaker bounds for multi-party calls and cleaner embeddings.
        // min: 2 forces VBx to look for multiple speakers (only system audio uses this path).
        // max: 8 prevents hallucinated splits from codec artifacts.
        // excludeOverlap: skip frames where 2+ speakers overlap, producing cleaner voiceprints.
        var offlineConfig = OfflineDiarizerConfig.default.withSpeakers(min: 2, max: 8)
        offlineConfig.embeddingExcludeOverlap = true
        let manager = OfflineDiarizerManager(config: offlineConfig)

        if let bundlePath = bundledModelsPath(directory: "offline-diarizer-models") {
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

    /// Check for diarization models bundled inside the app at build time.
    private func bundledModelsPath(directory: String) -> URL? {
        guard let resourcePath = Bundle.main.resourcePath else { return nil }

        let path = URL(fileURLWithPath: resourcePath)
            .appendingPathComponent(directory)
        guard FileManager.default.fileExists(atPath: path.path) else { return nil }

        return path
    }

    // MARK: - Offline Diarization (PyAnnote)

    /// Run offline speaker diarization on audio samples using PyAnnote pipeline.
    /// Supports unlimited speakers. Samples should be 16kHz mono Float32.
    nonisolated func diarizeOffline(samples: [Float], sampleRate: Int = 16000) async throws -> [SpeakerSegment] {
        guard let manager = await MainActor.run(body: { self.offlineDiarizerManager }) else {
            throw NSError(domain: "DiarizationService", code: 2, userInfo: [
                NSLocalizedDescriptionKey: "Offline diarizer model not loaded"
            ])
        }

        AppLogger.transcription.info("Offline diarization starting", ["samples": "\(samples.count)", "duration": "\(String(format: "%.1f", Double(samples.count) / Double(sampleRate)))s"])

        let result = try await manager.process(audio: samples)

        // Convert FluidAudio segments to our SpeakerSegment type
        let segments = result.segments.map { segment in
            SpeakerSegment(
                speakerId: speakerIdFromString(segment.speakerId),
                startTime: Double(segment.startTimeSeconds),
                endTime: Double(segment.endTimeSeconds),
                embedding: segment.embedding.isEmpty ? nil : segment.embedding,
                qualityScore: segment.qualityScore
            )
        }

        // Log summary
        let speakerIds = Set(segments.map { $0.speakerId })
        AppLogger.transcription.info("Offline diarization complete", ["segments": "\(segments.count)", "speakers": "\(speakerIds.count)"])
        for id in speakerIds.sorted() {
            let speakerSegments = segments.filter { $0.speakerId == id }
            let totalDuration = speakerSegments.reduce(0.0) { $0 + $1.duration }
            AppLogger.transcription.debug("Speaker \(id): \(speakerSegments.count) segments, \(String(format: "%.1f", totalDuration))s")
        }

        return segments
    }

    /// Run offline speaker diarization on a WAV file.
    nonisolated func diarizeOffline(audioURL: URL) async throws -> [SpeakerSegment] {
        let samples = try AudioResampler.loadAndResample(url: audioURL, targetRate: 16000)
        return try await diarizeOffline(samples: samples, sampleRate: 16000)
    }

    // MARK: - Streaming Diarization (Sortformer)

    /// Run streaming speaker diarization on audio samples using Sortformer.
    /// Limited to 4 speakers. Samples should be 16kHz mono Float32.
    nonisolated func diarizeStreaming(samples: [Float], sampleRate: Int = 16000) async throws -> [SpeakerSegment] {
        guard let manager = await MainActor.run(body: { self.diarizerManager }),
              manager.isAvailable else {
            throw NSError(domain: "DiarizationService", code: 1, userInfo: [
                NSLocalizedDescriptionKey: "Sortformer model not loaded"
            ])
        }

        AppLogger.transcription.info("Sortformer diarizing", ["samples": "\(samples.count)", "duration": "\(String(format: "%.1f", Double(samples.count) / Double(sampleRate)))s"])

        let result = try manager.performCompleteDiarization(samples, sampleRate: sampleRate)

        let segments = result.segments.map { segment in
            SpeakerSegment(
                speakerId: speakerIdFromString(segment.speakerId),
                startTime: Double(segment.startTimeSeconds),
                endTime: Double(segment.endTimeSeconds),
                embedding: segment.embedding.isEmpty ? nil : segment.embedding,
                qualityScore: segment.qualityScore
            )
        }

        let speakerIds = Set(segments.map { $0.speakerId })
        AppLogger.transcription.info("Sortformer diarization complete", ["segments": "\(segments.count)", "speakers": "\(speakerIds.count)"])
        for id in speakerIds.sorted() {
            let speakerSegments = segments.filter { $0.speakerId == id }
            let totalDuration = speakerSegments.reduce(0.0) { $0 + $1.duration }
            AppLogger.transcription.debug("Speaker \(id): \(speakerSegments.count) segments, \(String(format: "%.1f", totalDuration))s")
        }

        return segments
    }

    /// Run streaming speaker diarization on a WAV file.
    nonisolated func diarizeStreaming(audioURL: URL) async throws -> [SpeakerSegment] {
        let samples = try AudioResampler.loadAndResample(url: audioURL, targetRate: 16000)
        return try await diarizeStreaming(samples: samples, sampleRate: 16000)
    }

    // MARK: - Cleanup

    func cleanup() {
        diarizerManager = nil
        offlineDiarizerManager = nil
        modelState = .notLoaded
        offlineModelState = .notLoaded
    }

    // MARK: - Helpers

    /// Convert FluidAudio's string speaker ID (e.g., "speaker_0") to integer
    private nonisolated func speakerIdFromString(_ id: String) -> Int {
        // Sortformer uses "speaker_0", "speaker_1", etc.
        if let lastComponent = id.split(separator: "_").last,
           let intId = Int(lastComponent) {
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
