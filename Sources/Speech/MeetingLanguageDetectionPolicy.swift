import Foundation

/// Reduces independent acoustic-language observations, never transcript text.
/// WhisperKit 0.18 returns a winning token's natural-log probability, not a
/// full distribution; requiring agreement avoids inventing a runner-up margin.
struct MeetingLanguageDetectionPolicy {
    enum Outcome: Equatable {
        case detected(String)
        case uncertain
        case multilingual
    }

    static func confidentLanguage(code: String, logProbability: Float?, supportedCodes: Set<String>) -> String? {
        guard supportedCodes.contains(code), let logProbability,
              logProbability.isFinite, logProbability <= 0,
              exp(logProbability) >= 0.80 else { return nil }
        return code
    }

    static func resolve(_ observations: [String?]) -> Outcome {
        let confident = Set(observations.compactMap { $0 })
        if confident.count > 1 { return .multilingual }
        guard observations.count >= 2, observations.allSatisfy({ $0 != nil }),
              let code = confident.first else { return .uncertain }
        return .detected(code)
    }
}

/// The error that sends a saved-language retry to the settings fix. Its
/// "Select a Whisper model" wording is what `MeetingFailureKind` matches to show
/// that guidance instead of generic pipeline-failed copy.
enum TranscriptionLanguageModelErrors {
    /// A recording with a saved language reached a model that can't honor it.
    static func savedLanguageNeedsLanguageModel() -> NSError {
        NSError(domain: "STTRouter", code: 3, userInfo: [
            NSLocalizedDescriptionKey: "This recording has a saved language choice. Select a Whisper model in Settings to transcribe it in that language."
        ])
    }
}
