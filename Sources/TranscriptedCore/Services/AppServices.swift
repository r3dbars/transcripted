import Foundation

// MARK: - Dependency Injection Container
// Holds all service instances for loose coupling. Core is STT-agnostic —
// each app target (Transcripted standalone, the embedded app) constructs its own
// AppServices by passing a SpeechToTextEngine conformer it owns
// (ParakeetEngineAdapter in Transcripted standalone; MeetingSTTAdapter in
// `Sources/Meeting/` in this repo).
//
// Diarization and the speaker store are injected the same way. Core's own
// `DiarizationService` and `SpeakerDatabase` conform through empty
// extensions, so a host can pass them directly.

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
