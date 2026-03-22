import Foundation

// MARK: - Speaker Diarization Engine Protocol
// Conformer: DiarizationService

@available(macOS 14.0, *)
@MainActor
protocol DiarizationEngine: ObservableObject {
    /// Whether the diarization model is loaded and ready
    var isReady: Bool { get }

    /// Load/initialize the diarization model
    func initialize() async

    /// Perform offline diarization on audio samples
    /// - Parameters:
    ///   - samples: 16kHz mono Float32 audio samples
    ///   - sampleRate: Sample rate (default 16000)
    /// - Returns: Speaker segments with embeddings
    func diarizeOffline(samples: [Float], sampleRate: Int) async throws -> [SpeakerSegment]

    /// Perform offline diarization on an audio file
    /// - Parameter audioURL: Path to audio file
    /// - Returns: Speaker segments with embeddings
    func diarizeOffline(audioURL: URL) async throws -> [SpeakerSegment]

    /// Release model resources to free memory
    func cleanup()
}
