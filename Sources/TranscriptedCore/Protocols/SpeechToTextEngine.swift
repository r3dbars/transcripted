import Foundation
import FluidAudio

public struct SpeechTranscriptionEngineDescriptor: Equatable, Sendable {
    public let identifier: String
    public let displayName: String

    public init(identifier: String, displayName: String) {
        self.identifier = identifier
        self.displayName = displayName
    }

    public static let parakeetLocal = SpeechTranscriptionEngineDescriptor(
        identifier: "parakeet_local",
        displayName: "Parakeet"
    )
}

// MARK: - Speech-to-Text Engine Protocol
// Conformer: ParakeetService
// Note: AudioSource is defined by FluidAudio framework

@available(macOS 14.0, *)
@MainActor
public protocol SpeechToTextEngine: ObservableObject {
    /// Human/machine metadata for transcripts produced by this engine.
    var transcriptionEngineDescriptor: SpeechTranscriptionEngineDescriptor { get }

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

@available(macOS 14.0, *)
public extension SpeechToTextEngine {
    var transcriptionEngineDescriptor: SpeechTranscriptionEngineDescriptor {
        .parakeetLocal
    }
}
