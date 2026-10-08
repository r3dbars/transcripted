// SpeakerEmbedderChoiceResolution.swift
// The app's side of Core's `SpeakerVoiceprintSelection`: reads the stored
// preference and the environment, and maps Core's model to the app's
// `SpeakerEmbedderChoice`. The rule itself (default, environment override, stored
// WeSpeaker reading as the default) lives in Core so the CLI's import-audio
// resolves exactly the same model and speaker database as the app.

import Foundation
#if canImport(TranscriptedCore)
import TranscriptedCore
#endif

extension SpeakerEmbedderChoice {
    init(_ model: SpeakerVoiceprintSelection.Model) {
        switch model {
        case .weSpeaker: self = .weSpeaker
        case .eRes2Net: self = .eRes2Net
        case .reDimNet2: self = .reDimNet2
        }
    }

    var voiceprintModel: SpeakerVoiceprintSelection.Model {
        switch self {
        case .weSpeaker: return .weSpeaker
        case .eRes2Net: return .eRes2Net
        case .reDimNet2: return .reDimNet2
        }
    }
}

enum SpeakerEmbedderChoiceResolution {
    static var defaultChoice: SpeakerEmbedderChoice { SpeakerEmbedderChoice(SpeakerVoiceprintSelection.defaultModel) }

    /// The stored choice, ignoring any environment override.
    static func preferredChoice(userDefaults: UserDefaults = .standard) -> SpeakerEmbedderChoice {
        SpeakerEmbedderChoice(SpeakerVoiceprintSelection.preferredModel(
            storedPreference: userDefaults.string(forKey: SpeakerVoiceprintSelection.preferenceKey)
        ))
    }

    /// The choice a run should use: environment override, stored preference, default.
    static func effectiveChoice(
        userDefaults: UserDefaults = .standard,
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) -> SpeakerEmbedderChoice {
        SpeakerEmbedderChoice(SpeakerVoiceprintSelection.effectiveModel(
            storedPreference: userDefaults.string(forKey: SpeakerVoiceprintSelection.preferenceKey),
            environment: environment
        ))
    }
}
