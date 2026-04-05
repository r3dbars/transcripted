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

// NOTE: Visibility kept `internal` here — Step 6 (merge-plan §1.4) will
// upgrade AppServices, the protocols, and ~44 other types to `public` in
// one coordinated pass so the visibility surface can be reviewed together.
@MainActor
struct AppServices {
    let speechToText: any SpeechToTextEngine
    let diarization: any DiarizationEngine
    let speakerStore: any SpeakerStore

    init(
        speechToText: any SpeechToTextEngine,
        diarization: any DiarizationEngine,
        speakerStore: any SpeakerStore
    ) {
        self.speechToText = speechToText
        self.diarization = diarization
        self.speakerStore = speakerStore
    }
}
