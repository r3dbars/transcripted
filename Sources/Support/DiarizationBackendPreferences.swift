// DiarizationBackendPreferences.swift
// Hidden, off-by-default switch for which speaker-diarization model splits
// meeting call audio into speaker turns. pyannote (FluidAudio's offline
// pipeline) is what every meeting uses today; Nemotron is NVIDIA's Nemotron 3
// Diarization, kept behind this switch until the speaker lab shows it wins.
// There is no Settings UI on purpose. Mirrors `SpeakerEmbedderPreferences`,
// and stays free of TranscriptedCore so the fast-test runner can compile it
// directly; MeetingSessionController maps the choice onto Core's
// `DiarizationBackend`.
//
// Turn it on for a local test:
//   defaults write com.justinbetker.draft diarization-backend-preference nemotron
// or launch with TRANSCRIPTED_DIARIZATION_BACKEND=nemotron. Takes effect on the
// next app launch.

import Foundation

enum DiarizationBackendChoice: String, CaseIterable, Identifiable {
    case pyannote
    case nemotron

    var id: String { rawValue }
}

enum DiarizationBackendPreferences {
    static let defaultChoice: DiarizationBackendChoice = .pyannote

    static let preferenceKey = "diarization-backend-preference"
    /// Dev/lab override, e.g. `TRANSCRIPTED_DIARIZATION_BACKEND=nemotron`. Wins over
    /// the persisted preference.
    static let envKey = "TRANSCRIPTED_DIARIZATION_BACKEND"

    /// The stored choice, ignoring any environment override.
    static func preferredChoice(userDefaults: UserDefaults = .standard) -> DiarizationBackendChoice {
        guard
            let raw = userDefaults.string(forKey: preferenceKey)?.lowercased(),
            let choice = DiarizationBackendChoice(rawValue: raw)
        else { return defaultChoice }
        return choice
    }

    /// The choice to use at runtime: environment override first, then the stored
    /// preference, then the default.
    static func effectiveChoice(
        userDefaults: UserDefaults = .standard,
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) -> DiarizationBackendChoice {
        if let raw = environment[envKey]?.lowercased(),
           let choice = DiarizationBackendChoice(rawValue: raw) {
            return choice
        }
        return preferredChoice(userDefaults: userDefaults)
    }

    static func setPreferredChoice(_ choice: DiarizationBackendChoice, userDefaults: UserDefaults = .standard) {
        userDefaults.set(choice.rawValue, forKey: preferenceKey)
    }
}
