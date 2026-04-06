import Foundation

// MARK: - Dependency Injection Container
// Holds all service instances for loose coupling. Core is STT-agnostic —
// each app target (Transcripted standalone, Draft) constructs its own
// AppServices by passing a SpeechToTextEngine conformer it owns
// (ParakeetEngineAdapter in Transcripted standalone; MeetingSTTAdapter in
// Draft's Sources/Meeting/).
//
// Diarization, stats, and the speaker store still default to Core's
// concrete implementations via empty extensions (see Step 8 wiring).

@available(macOS 14.0, *)
@MainActor
public struct AppServices {
    public let speechToText: any SpeechToTextEngine
    public let diarization: any DiarizationEngine
    public let speakerStore: any SpeakerStore

    public init(
        speechToText: any SpeechToTextEngine,
        diarization: any DiarizationEngine,
        speakerStore: any SpeakerStore
    ) {
        self.speechToText = speechToText
        self.diarization = diarization
        self.speakerStore = speakerStore
    }
}
