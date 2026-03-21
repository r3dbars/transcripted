import Foundation

// MARK: - Dependency Injection Container
// Holds all service instances for loose coupling.
// Created once in AppDelegate.setupApp() and passed to managers.
//
// Protocols are defined in Services/Protocols/ but conformances are not yet added.
// Once conformances are added, switch these to protocol types (any SpeechToTextEngine, etc.)

@available(macOS 14.0, *)
@MainActor
struct AppServices {
    let speechToText: ParakeetService
    let diarization: DiarizationService
    let speakerNaming: QwenService
    let speakerStore: SpeakerDatabase

    /// Creates the default production configuration
    static func makeDefault() -> AppServices {
        return AppServices(
            speechToText: ParakeetService(),
            diarization: DiarizationService(),
            speakerNaming: QwenService(),
            speakerStore: SpeakerDatabase.shared
        )
    }
}
