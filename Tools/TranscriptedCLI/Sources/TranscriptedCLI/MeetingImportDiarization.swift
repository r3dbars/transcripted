#if TRANSCRIPTEDCLI_WITH_MEETING_IMPORT
import Foundation
import TranscriptedCore

/// Which diarization engine `import-audio` runs. `--diarization-engine app`
/// (the default) follows Core's `DiarizationBackend.effective`, the same rule
/// the app uses: the stored preference or `TRANSCRIPTED_DIARIZATION_BACKEND`,
/// Nemotron when nothing is set. An explicit `nemotron` or `pyannote` wins.
enum MeetingImportDiarization {
    static let preferenceKey = DiarizationBackend.preferenceKey
    static let environmentKey = DiarizationBackend.environmentKey
    static let hostDefault = DiarizationBackend.hostDefault

    static func backend(
        choice: String,
        environment: [String: String] = ProcessInfo.processInfo.environment,
        appDefaults: [String: Any]? = UserDefaults.standard.persistentDomain(
            forName: CLIDiarization.appDefaultsDomain
        )
    ) throws -> DiarizationBackend {
        let raw = try CLIDiarization.resolvedEngine(
            choice: choice,
            environment: environment,
            storedPreference: appDefaults?[preferenceKey] as? String
        )
        guard let backend = DiarizationBackend(rawValue: raw) else {
            throw CLIDiarization.UnknownEngine(value: raw)
        }
        return backend
    }

    /// `DiarizationService` asks for a named bundle. Nemotron and pyannote must
    /// not share a folder: handing Nemotron the pyannote path makes it fail
    /// the load and fall back to pyannote.
    static func bundleProvider(pyannote: URL?, nemotron: URL?) -> ModelBundleProvider {
        { name in
            switch name {
            case "offline-diarizer-models":
                return pyannote
            case "nemotron-diarizer-models":
                return nemotron
            default:
                return nil
            }
        }
    }
}
#endif
