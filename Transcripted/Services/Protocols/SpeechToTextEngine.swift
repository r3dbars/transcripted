import Foundation
import FluidAudio

// MARK: - Speech-to-Text Engine Protocol
// Conformer: ParakeetService
// Note: AudioSource is defined by FluidAudio framework

@available(macOS 14.0, *)
@MainActor
protocol SpeechToTextEngine: ObservableObject {
    /// Whether the model is loaded and ready for transcription
    var isReady: Bool { get }

    /// Load/initialize the speech recognition model
    func initialize() async

    /// Transcribe audio samples to text
    /// - Parameters:
    ///   - samples: 16kHz mono Float32 audio samples
    ///   - source: Whether this is mic or system audio (FluidAudio.AudioSource)
    /// - Returns: Transcribed text
    func transcribeSegment(samples: [Float], source: AudioSource) async throws -> String

    /// Release model resources to free memory
    func cleanup()
}
