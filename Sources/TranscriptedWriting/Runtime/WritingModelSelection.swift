import Foundation
#if canImport(TranscriptedWritingCore)
import TranscriptedWritingCore
#endif

/// Selection for the official Tilde app. Preview identities keep their own
/// fixed/experimental selection rules and cannot retarget production.
enum TildeModelSelection {
    static let defaultsKey = "SelectedModelChoice"

    static func choice(
        for profile: TildeProductProfile,
        defaults: UserDefaults? = nil
    ) -> TildeModelChoice? {
        guard profile == .production else { return nil }
        return TildeModelChoice.resolve(
            persistedValue: (defaults ?? .standard).string(forKey: defaultsKey)
        )
    }

    static func descriptor(
        for profile: TildeProductProfile,
        productionChoice: TildeModelChoice?
    ) -> ModelDescriptor {
        switch productionChoice {
        case .gemma4E2B: .gemma4E2BQ4KM
        case .qwen35B9B: .qwen35B9BQ4KM
        case nil: profile == .preview9B ? .qwen35B9BQ4KM : .gemma4E2BQ4KM
        }
    }

    static func completionProfile(
        for profile: TildeProductProfile,
        productionChoice: TildeModelChoice?
    ) -> TildeProductProfile {
        if productionChoice == .qwen35B9B { return .preview9B }
        return profile
    }

    static func persist(_ choice: TildeModelChoice, defaults: UserDefaults? = nil) {
        (defaults ?? .standard).set(choice.rawValue, forKey: defaultsKey)
    }
}
