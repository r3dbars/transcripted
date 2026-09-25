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

    func resolveLanguage(representativeSamples: [[Float]], selection: TranscriptionLanguageSelection) async throws -> TranscriptionLanguageContext
    func transcribeSegment(samples: [Float], source: AudioSource, language: TranscriptionLanguageContext) async throws -> String

    /// Largest packed input, in 16 kHz samples, that one call covers at a
    /// fixed cost. nil (the default) means the engine does not pack, and the
    /// pipeline makes one call per segment.
    var packedSegmentWindowSamples: Int? { get }

    /// Transcribes several short segments in one call and returns one text per
    /// segment, in order (see `SpeechSegmentPacking`). nil means this call
    /// can't be packed; the pipeline then makes one call per segment.
    func transcribePackedSegments(
        _ segments: [[Float]],
        source: AudioSource,
        language: TranscriptionLanguageContext
    ) async throws -> [String]?

    /// Release model resources to free memory
    func cleanup()
}

@available(macOS 14.0, *)
public extension SpeechToTextEngine {
    func resolveLanguage(representativeSamples: [[Float]], selection: TranscriptionLanguageSelection) async throws -> TranscriptionLanguageContext {
        guard selection == .automatic else { throw TranscriptionLanguageError.explicitLanguageUnsupported }
        return TranscriptionLanguageContext(selection: selection, languageCode: nil, resolution: .unsupported)
    }

    func transcribeSegment(samples: [Float], source: AudioSource, language: TranscriptionLanguageContext) async throws -> String {
        guard language.selection == .automatic else { throw TranscriptionLanguageError.explicitLanguageUnsupported }
        return try await transcribeSegment(samples: samples, source: source)
    }
    var transcriptionEngineDescriptor: SpeechTranscriptionEngineDescriptor {
        .parakeetLocal
    }

    var packedSegmentWindowSamples: Int? { nil }

    func transcribePackedSegments(
        _ segments: [[Float]],
        source: AudioSource,
        language: TranscriptionLanguageContext
    ) async throws -> [String]? {
        nil
    }
}
