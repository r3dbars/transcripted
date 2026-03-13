// SortformerService.swift
// Local speaker diarization using FluidAudio's Sortformer + WeSpeaker embedding model.
// Identifies speaker segments and extracts 256-dim voice fingerprints.

import Foundation
import FluidAudio

/// A speaker segment from diarization with optional voice fingerprint
struct SpeakerSegment {
    let speakerId: Int          // 0, 1, 2, 3 (Sortformer supports 4 speakers)
    let startTime: Double       // seconds
    let endTime: Double         // seconds
    let embedding: [Float]?     // 256-dim voice fingerprint (from WeSpeaker)
    let qualityScore: Float     // Segment quality (0-1)

    var duration: Double { endTime - startTime }
}

enum SortformerModelState: Equatable {
    case notLoaded
    case loading
    case ready
    case failed(String)
}

@available(macOS 14.0, *)
@MainActor
class SortformerService: ObservableObject {
    @Published var modelState: SortformerModelState = .notLoaded

    private var diarizerManager: DiarizerManager?

    var isReady: Bool { diarizerManager?.isAvailable ?? false }

    // MARK: - Model Initialization

    /// Load Sortformer + embedding models from the app bundle or download from HuggingFace.
    func initialize() async {
        guard diarizerManager == nil else {
            AppLogger.transcription.debug("Sortformer already initialized")
            return
        }

        modelState = .loading
        AppLogger.transcription.info("Sortformer initializing models")

        do {
            let manager = DiarizerManager(config: .default)

            // Try loading from bundle first, fall back to download
            if let bundlePath = bundledModelsPath() {
                AppLogger.transcription.info("Sortformer loading from bundle", ["path": "\(bundlePath)"])
                let models = try await DiarizerModels.load(from: bundlePath)
                manager.initialize(models: models)
            } else {
                AppLogger.transcription.info("Sortformer models not bundled, downloading")
                let models = try await DiarizerModels.download()
                manager.initialize(models: models)
            }

            diarizerManager = manager
            modelState = .ready
            AppLogger.transcription.info("Sortformer models loaded and ready")
        } catch {
            modelState = .failed(error.localizedDescription)
            AppLogger.transcription.error("Sortformer model initialization failed", ["error": "\(error.localizedDescription)"])
        }
    }

    /// Check for diarization models bundled inside the app at build time.
    private func bundledModelsPath() -> URL? {
        guard let resourcePath = Bundle.main.resourcePath else { return nil }

        // Check for sortformer models directory
        let sortformerPath = URL(fileURLWithPath: resourcePath)
            .appendingPathComponent("sortformer-models")
        guard FileManager.default.fileExists(atPath: sortformerPath.path) else { return nil }

        return sortformerPath
    }

    // MARK: - Diarization

    /// Run speaker diarization on audio samples.
    /// Samples should be 16kHz mono Float32.
    nonisolated func diarize(samples: [Float], sampleRate: Int = 16000) async throws -> [SpeakerSegment] {
        // Hop to MainActor briefly to get the manager reference, then do CPU work off main
        guard let manager = await MainActor.run(body: { self.diarizerManager }),
              manager.isAvailable else {
            throw NSError(domain: "SortformerService", code: 1, userInfo: [
                NSLocalizedDescriptionKey: "Sortformer model not loaded"
            ])
        }

        AppLogger.transcription.info("Sortformer diarizing", ["samples": "\(samples.count)", "duration": "\(String(format: "%.1f", Double(samples.count) / Double(sampleRate)))s"])

        let result = try manager.performCompleteDiarization(samples, sampleRate: sampleRate)

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
        AppLogger.transcription.info("Sortformer diarization complete", ["segments": "\(segments.count)", "speakers": "\(speakerIds.count)"])
        for id in speakerIds.sorted() {
            let speakerSegments = segments.filter { $0.speakerId == id }
            let totalDuration = speakerSegments.reduce(0.0) { $0 + $1.duration }
            AppLogger.transcription.debug("Speaker \(id): \(speakerSegments.count) segments, \(String(format: "%.1f", totalDuration))s")
        }

        return segments
    }

    /// Run speaker diarization on a WAV file.
    nonisolated func diarize(audioURL: URL) async throws -> [SpeakerSegment] {
        let samples = try AudioResampler.loadAndResample(url: audioURL, targetRate: 16000)
        return try await diarize(samples: samples, sampleRate: 16000)
    }

    // MARK: - Cleanup

    func cleanup() {
        diarizerManager = nil
        modelState = .notLoaded
    }

    // MARK: - Helpers

    /// Convert FluidAudio's string speaker ID (e.g., "speaker_0") to integer
    private nonisolated func speakerIdFromString(_ id: String) -> Int {
        // FluidAudio uses format like "speaker_0", "speaker_1", etc.
        if let lastComponent = id.split(separator: "_").last,
           let intId = Int(lastComponent) {
            return intId
        }
        // Fallback: try direct Int parsing
        return Int(id) ?? 0
    }
}
