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
