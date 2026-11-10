// SpeakerEmbedderPreferences.swift
// Persisted choice of speaker-embedding ("voiceprint") model used by meeting
// diarization. ReDimNet2 (192-dim, Palabra.ai) is the default since the voiceprint
// bake-off (Tools/SpeakerEvalHarness/VOICEPRINT_RESULTS.md): it recognizes more
// people on call audio with zero wrong names. WeSpeaker is the diarizer's built-in
// 256-dim model, used before and still the fallback when ReDimNet2 can't load.
// ERes2Net is a 192-dim model the bake-off found weaker than WeSpeaker; kept only
// for anyone who chose it. Each runs after diarization to drive same-voice
// consolidation + cross-call speaker matching, and each has its own speaker
// database. Which model a run actually uses is decided in Core's
// `SpeakerVoiceprintSelection`, shared with the CLI.

import Foundation

enum SpeakerEmbedderChoice: String, CaseIterable, Identifiable {
    case weSpeaker = "wespeaker"
    case eRes2Net = "eres2net"
    case reDimNet2 = "redimnet2"

    var id: String { rawValue }
}

enum SpeakerEmbedderPreferences {
    /// Must equal Core's `SpeakerVoiceprintSelection.preferenceKey` (the CLI reads
    /// it from the app's defaults); a fast test pins the two together. Reading the
    /// preference, the default and the fallback rules live in Core
    /// (`SpeakerVoiceprintSelection`, reached through Meeting's
    /// `SpeakerEmbedderChoiceResolution`) so the app and the CLI share one rule.
    static let preferenceKey = "speaker-embedder-preference"

    static func setPreferredChoice(_ choice: SpeakerEmbedderChoice, userDefaults: UserDefaults = .standard) {
        userDefaults.set(choice.rawValue, forKey: preferenceKey)
    }
}
