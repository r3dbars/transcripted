import Foundation

/// Engine choice and windowing shared by every CLI diarization path
/// (`import-audio`, `diarize`, `batch`).
///
/// Stub values still match today's `diarize`/`batch` (pyannote, FluidAudio's
/// default 0.2 step). Tests pin the app-tuned 0.266 step and the Nemotron
/// host default so this file has to change before they go green.
enum CLIDiarization {
    static let engineChoices = ["app", "nemotron", "pyannote"]
    static let defaultEngineChoice = "app"
    static let preferenceKey = "diarization-backend-preference"
    static let environmentKey = "TRANSCRIPTED_DIARIZATION_BACKEND"

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

    /// Today's standalone `diarize` config: FluidAudio `OfflineDiarizerConfig.default`
    /// uses a 0.2 step (1903 windows on a 3806 s file). The app and `import-audio`
    /// use 0.266 (1431 windows on that file).
    static var windowing: Windowing {
        Windowing(windowDuration: 10.0, segmentationStepRatio: 0.2, nemotronSliceSeconds: 10.0)
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

    /// Today's `diarize`/`batch` always run pyannote, ignoring the app default.
    static func resolvedEngine(
        choice: String,
        environment: [String: String] = [:],
        storedPreference: String? = nil
    ) -> String {
        _ = (environment, storedPreference)
        if choice != "app", engineChoices.contains(choice) {
            return choice
        }
        return "pyannote"
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
