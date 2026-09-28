import Foundation

func testDiarizationBackendPreferences() {
    func makeDefaults() -> (UserDefaults, String) {
        let suiteName = "DiarizationBackendPreferencesTests-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defaults.removePersistentDomain(forName: suiteName)
        return (defaults, suiteName)
    }
    let envKey = "TRANSCRIPTED_DIARIZATION_BACKEND"

    runSuite("Diarization backend defaults to Nemotron") {
        let (d, s) = makeDefaults(); defer { d.removePersistentDomain(forName: s) }
        assertEqual(DiarizationBackendPreferences.defaultChoice.rawValue, "nemotron", "Nemotron is the default")
        assertEqual(DiarizationBackendPreferences.effectiveChoice(userDefaults: d, environment: [:]).rawValue, "nemotron", "no env, no UD -> default")
        assertEqual(DiarizationBackendPreferences.envKey, envKey, "env key is the documented one")
        assertEqual(DiarizationBackendPreferences.preferenceKey, "diarization-backend-preference", "defaults key is the documented one")
    }

    runSuite("Diarization backend honors the environment override") {
        let (d, s) = makeDefaults(); defer { d.removePersistentDomain(forName: s) }
        assertEqual(DiarizationBackendPreferences.effectiveChoice(userDefaults: d, environment: [envKey: "pyannote"]).rawValue, "pyannote", "env pyannote")
        assertEqual(DiarizationBackendPreferences.effectiveChoice(userDefaults: d, environment: [envKey: "PYANNOTE"]).rawValue, "pyannote", "uppercase is lowercased")
        assertEqual(DiarizationBackendPreferences.effectiveChoice(userDefaults: d, environment: [envKey: "garbage"]).rawValue, "nemotron", "garbage env -> default")
    }

    runSuite("Diarization backend persistence and env precedence") {
        let (d, s) = makeDefaults(); defer { d.removePersistentDomain(forName: s) }
        DiarizationBackendPreferences.setPreferredChoice(.pyannote, userDefaults: d)
        assertEqual(DiarizationBackendPreferences.preferredChoice(userDefaults: d).rawValue, "pyannote", "persisted preference")
        assertEqual(DiarizationBackendPreferences.effectiveChoice(userDefaults: d, environment: [:]).rawValue, "pyannote", "no env -> UserDefaults wins")
        assertEqual(DiarizationBackendPreferences.effectiveChoice(userDefaults: d, environment: [envKey: "nemotron"]).rawValue, "nemotron", "env overrides UserDefaults")
        d.set("Pyannote", forKey: DiarizationBackendPreferences.preferenceKey)
        assertEqual(DiarizationBackendPreferences.preferredChoice(userDefaults: d).rawValue, "pyannote", "defaults write with capitals still reads")
    }
}
