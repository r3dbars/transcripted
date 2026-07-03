// SpeakerEmbedderPreferences.swift
// Persisted choice of speaker-embedding ("voiceprint") model used by meeting
// diarization. WeSpeaker is the diarizer's built-in 256-dim model; ERes2Net is a
// 192-dim on-device model that is more robust to compressed (Zoom/phone) audio
// and runs after diarization to drive same-voice consolidation + cross-call
// speaker matching. Mirrors `TranscriptionModelPreferences`.

import Foundation

enum SpeakerEmbedderChoice: String, CaseIterable, Identifiable {
    case weSpeaker = "wespeaker"
    case eRes2Net = "eres2net"

    var id: String { rawValue }

    var title: String {
        switch self {
        case .weSpeaker: return "WeSpeaker (built-in)"
        case .eRes2Net: return "ERes2Net (codec-robust)"
        }
    }

    var shortTitle: String {
        switch self {
        case .weSpeaker: return "WeSpeaker"
        case .eRes2Net: return "ERes2Net"
        }
    }

    var summary: String {
        switch self {
        case .weSpeaker:
            return "The diarizer's default 256-dim voiceprint."
        case .eRes2Net:
            return "On-device 192-dim voiceprint; better at keeping different people apart on compressed call audio. Uses a separate speaker memory."
        }
    }
}

enum SpeakerEmbedderPreferences {
    static let defaultChoice: SpeakerEmbedderChoice = .weSpeaker

    private static let preferenceKey = "speaker-embedder-preference"
    /// Dev/test override, e.g. `TRANSCRIPTED_SPEAKER_EMBEDDER=eres2net`. Wins over
    /// the persisted preference so the feature can be exercised without UI.
    private static let envKey = "TRANSCRIPTED_SPEAKER_EMBEDDER"

    /// The user's stored choice, ignoring any environment override. Use this to
    /// drive the Settings UI selection.
    static func preferredChoice(userDefaults: UserDefaults = .standard) -> SpeakerEmbedderChoice {
        guard
            let raw = userDefaults.string(forKey: preferenceKey),
            let choice = SpeakerEmbedderChoice(rawValue: raw)
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

    /// Speaker-database filename for a given *loaded* embedder identifier. A nil
    /// identifier — the default WeSpeaker path, or an ERes2Net model that was
    /// selected but could not be loaded — maps to the legacy `speakers.sqlite`.
    /// Any other embedder gets its own `speakers_<id>.sqlite` so vectors of
    /// different dimensions can never share a database row. Keying on the loaded
    /// embedder (not mere model-file presence) is what keeps the per-model DBs
    /// dimension-pure even when a present model fails to load.
    static func speakerDBFileName(forEmbedderIdentifier identifier: String?) -> String {
        guard let identifier, !identifier.isEmpty else { return "speakers.sqlite" }
        return "speakers_\(identifier).sqlite"
    }
}

extension Notification.Name {
    static let speakerEmbedderPreferenceDidChange = Notification.Name("speakerEmbedderPreferenceDidChange")
}
