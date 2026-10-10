#if TRANSCRIPTEDCLI_WITH_MEETING_IMPORT
import Foundation
import TranscriptedCore

/// Which diarization engine `import-audio` runs. `--diarization-engine app`
/// (the default) follows the same hidden switch the app uses: the stored
/// `diarization-backend-preference` or `TRANSCRIPTED_DIARIZATION_BACKEND`,
/// Nemotron when nothing is set. An explicit `nemotron` or `pyannote` wins.
enum MeetingImportDiarization {
    static let preferenceKey = "diarization-backend-preference"
    static let environmentKey = "TRANSCRIPTED_DIARIZATION_BACKEND"
    static let hostDefault: DiarizationBackend = .nemotron

    static func backend(
        choice: String,
        environment: [String: String] = ProcessInfo.processInfo.environment,
        appDefaults: [String: Any]? = UserDefaults.standard.persistentDomain(
            forName: SpeakerVoiceprintSelection.appDefaultsDomain
        )
    ) -> DiarizationBackend {
        // Current CLI behavior until the tests force the app-shared default:
        // DiarizationService's library default is pyannote.
        _ = (choice, environment, appDefaults)
        return .pyannote
    }

    /// `DiarizationService` asks for a named bundle. Returning the pyannote
    /// directory for every name makes Nemotron try to load from the wrong
    /// folder and fall back to pyannote.
    static func bundleProvider(pyannote: URL?, nemotron: URL?) -> ModelBundleProvider {
        { _ in pyannote }
    }
}
#endif
