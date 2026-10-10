import Foundation
#if TRANSCRIPTEDCLI_WITH_MEETING_IMPORT && canImport(TranscriptedCore)
import TranscriptedCore
#if canImport(FluidAudio)
@preconcurrency import FluidAudio
#endif
#endif

/// Engine choice and windowing shared by every CLI diarization path
/// (`import-audio`, `diarize`, `batch`). One source so the two pyannote
/// configs cannot drift the way 1431 vs 1903 windows did.
enum CLIDiarization {
    static let engineChoices = ["app", "nemotron", "pyannote"]
    static let defaultEngineChoice = "app"
    static let preferenceKey = "diarization-backend-preference"
    static let environmentKey = "TRANSCRIPTED_DIARIZATION_BACKEND"
    /// Same domain the app writes (`SpeakerVoiceprintSelection.appDefaultsDomain`).
    static let appDefaultsDomain = "com.justinbetker.draft"

    struct Windowing: Equatable {
        var windowDuration: Double
        var segmentationStepRatio: Double
        var nemotronSliceSeconds: Double

        func pyannoteWindowCount(audioDurationSeconds: Double) -> Int {
            CLIDiarization.windowCount(
                audioDurationSeconds: audioDurationSeconds,
                windowDuration: windowDuration,
                stepRatio: segmentationStepRatio
            )
        }

        func nemotronWindowCount(audioDurationSeconds: Double) -> Int {
            guard nemotronSliceSeconds > 0, audioDurationSeconds > 0 else { return 0 }
            return Int(ceil(audioDurationSeconds / nemotronSliceSeconds))
        }
    }

    /// App-tuned pyannote knobs (`FluidAudioCompatibility.tunedOfflineDiarizerConfig`
    /// when Core is linked) plus Nemotron's 10 s feed slice.
    static var windowing: Windowing {
        #if TRANSCRIPTEDCLI_WITH_MEETING_IMPORT && canImport(TranscriptedCore) && canImport(FluidAudio)
        let config = FluidAudioCompatibility.tunedOfflineDiarizerConfig()
        return Windowing(
            windowDuration: config.windowDuration,
            segmentationStepRatio: config.segmentationStepRatio,
            nemotronSliceSeconds: 10.0
        )
        #else
        return Windowing(windowDuration: 10.0, segmentationStepRatio: 0.266, nemotronSliceSeconds: 10.0)
        #endif
    }

    static func windowCount(
        audioDurationSeconds: Double,
        windowDuration: Double,
        stepRatio: Double
    ) -> Int {
        let hop = windowDuration * stepRatio
        guard hop > 0, audioDurationSeconds > 0 else { return 0 }
        return Int((audioDurationSeconds / hop).rounded())
    }

    /// `app` follows the same rule the Mac app uses: environment, then the
    /// stored preference, then Nemotron. An explicit `nemotron` or `pyannote`
    /// wins.
    static func storedAppPreference(
        appDefaults: [String: Any]? = UserDefaults.standard.persistentDomain(forName: appDefaultsDomain)
    ) -> String? {
        appDefaults?[preferenceKey] as? String
    }

    static func resolvedEngine(
        choice: String,
        environment: [String: String] = ProcessInfo.processInfo.environment,
        storedPreference: String? = nil
    ) -> String {
        let trimmed = choice.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        if trimmed != "app" {
            return engineChoices.contains(trimmed) ? trimmed : "nemotron"
        }
        #if TRANSCRIPTEDCLI_WITH_MEETING_IMPORT && canImport(TranscriptedCore)
        return DiarizationBackend.effective(
            storedPreference: storedPreference,
            environment: environment
        ).rawValue
        #else
        if let raw = environment[environmentKey]?.lowercased(),
           raw == "nemotron" || raw == "pyannote" {
            return raw
        }
        if let raw = storedPreference?.lowercased(),
           raw == "nemotron" || raw == "pyannote" {
            return raw
        }
        return "nemotron"
        #endif
    }
}

extension ImportAudio {
    static var sharedDiarizationWindowing: CLIDiarization.Windowing { CLIDiarization.windowing }
}

extension Diarize {
    static var sharedDiarizationWindowing: CLIDiarization.Windowing { CLIDiarization.windowing }
}

extension Batch {
    static var sharedDiarizationWindowing: CLIDiarization.Windowing { CLIDiarization.windowing }
}
