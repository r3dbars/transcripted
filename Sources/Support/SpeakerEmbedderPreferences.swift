// SpeakerEmbedderPreferences.swift
// Persisted choice of speaker-embedding ("voiceprint") model used by meeting
// diarization. ReDimNet2 (192-dim, Palabra.ai) is the default since the voiceprint
// bake-off (Tools/SpeakerEvalHarness/VOICEPRINT_RESULTS.md): it recognizes more
// people on call audio with zero wrong names. WeSpeaker is the diarizer's built-in
// 256-dim model, used before and still the fallback when ReDimNet2 can't load.
// ERes2Net is a 192-dim model the bake-off found weaker than WeSpeaker; kept only
// for anyone who chose it. Each runs after diarization to drive same-voice
// consolidation + cross-call speaker matching, and each has its own speaker
// database. Mirrors `TranscriptionModelPreferences`.

import Foundation

enum SpeakerEmbedderChoice: String, CaseIterable, Identifiable {
    case weSpeaker = "wespeaker"
    case eRes2Net = "eres2net"
    case reDimNet2 = "redimnet2"

    var id: String { rawValue }

    var title: String {
        switch self {
        case .weSpeaker: return "WeSpeaker (built-in)"
        case .eRes2Net: return "ERes2Net (codec-robust)"
        case .reDimNet2: return "ReDimNet2 (default)"
        }
    }

    var shortTitle: String {
        switch self {
        case .weSpeaker: return "WeSpeaker"
        case .eRes2Net: return "ERes2Net"
        case .reDimNet2: return "ReDimNet2"
        }
    }

    var summary: String {
        switch self {
        case .weSpeaker:
            return "The diarizer's default 256-dim voiceprint."
        case .eRes2Net:
            return "On-device 192-dim voiceprint; better at keeping different people apart on compressed call audio. Uses a separate speaker memory."
        case .reDimNet2:
            return "On-device 192-dim voiceprint; recognizes more people on call audio. Uses a separate speaker memory, filled from your saved people on first use."
        }
    }
}

enum SpeakerEmbedderPreferences {
    static let defaultChoice: SpeakerEmbedderChoice = .reDimNet2

    private static let preferenceKey = "speaker-embedder-preference"
    /// Dev/test override, e.g. `TRANSCRIPTED_SPEAKER_EMBEDDER=eres2net`. Wins over
    /// the persisted preference so the feature can be exercised without UI.
    private static let envKey = "TRANSCRIPTED_SPEAKER_EMBEDDER"

    /// The user's stored choice, ignoring any environment override. A stored
    /// WeSpeaker came from the old "Better matching on calls" switch being off;
    /// that switch is gone and the call-audio model is always on, so it reads as
    /// the default. WeSpeaker is still reachable through the env override and as
    /// the fallback when ReDimNet2 can't load.
    static func preferredChoice(userDefaults: UserDefaults = .standard) -> SpeakerEmbedderChoice {
        guard
            let raw = userDefaults.string(forKey: preferenceKey),
            let choice = SpeakerEmbedderChoice(rawValue: raw),
            choice != .weSpeaker
        else { return defaultChoice }
        return choice
    }

    /// The choice that should actually be used at runtime: environment override
    /// first, then the stored preference, then the default.
    static func effectiveChoice(
        userDefaults: UserDefaults = .standard,
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) -> SpeakerEmbedderChoice {
        if let raw = environment[envKey]?.lowercased(),
           let choice = SpeakerEmbedderChoice(rawValue: raw) {
            return choice
        }
        return preferredChoice(userDefaults: userDefaults)
    }

    static func setPreferredChoice(_ choice: SpeakerEmbedderChoice, userDefaults: UserDefaults = .standard) {
        userDefaults.set(choice.rawValue, forKey: preferenceKey)
        NotificationCenter.default.post(name: .speakerEmbedderPreferenceDidChange, object: nil)
    }

    /// Speaker-database filename for the embedder the meeting stack is built
    /// around. A nil identifier (WeSpeaker, or a chosen model whose file is missing
    /// or that failed to load on this build) maps to the legacy `speakers.sqlite`.
    /// Any other embedder gets its own `speakers_<id>.sqlite` so vectors of
    /// different dimensions can never share a database row. A model that fails its
    /// background load after launch produces no vectors at all, so its database
    /// stays dimension-pure too (SpeakerEmbedderFactory).
    static func speakerDBFileName(forEmbedderIdentifier identifier: String?) -> String {
        guard let identifier, !identifier.isEmpty else { return "speakers.sqlite" }
        return "speakers_\(identifier).sqlite"
    }
}

extension Notification.Name {
    static let speakerEmbedderPreferenceDidChange = Notification.Name("speakerEmbedderPreferenceDidChange")
}
