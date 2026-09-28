// DiarizationBackendPreferences.swift
// Hidden switch for which speaker-diarization model splits meeting call audio
// into speaker turns. Nemotron (NVIDIA's Nemotron 3 Diarization) is the default:
// in the YODAS3 speaker lab it got 7-person calls exactly right 80% of the time
// against 0% for pyannote (FluidAudio's offline pipeline), with no people
// blended together (Tools/SpeakerEvalHarness/YODAS_LAB_RESULTS.md). pyannote
// stays one switch away, and DiarizationService falls back to it on its own
// when Nemotron can't load. There is no Settings UI on purpose. Mirrors `SpeakerEmbedderPreferences`,
// and stays free of TranscriptedCore so the fast-test runner can compile it
// directly; MeetingSessionController maps the choice onto Core's
// `DiarizationBackend`.
//
// Switch back for a local comparison:
//   defaults write com.justinbetker.draft diarization-backend-preference pyannote
// or launch with TRANSCRIPTED_DIARIZATION_BACKEND=pyannote. Takes effect on the
// next app launch.

import Foundation

enum DiarizationBackendChoice: String, CaseIterable, Identifiable {
    case pyannote
    case nemotron

    var id: String { rawValue }
}

enum DiarizationBackendPreferences {
    static let defaultChoice: DiarizationBackendChoice = .nemotron

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
