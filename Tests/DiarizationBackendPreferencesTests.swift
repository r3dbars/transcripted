import Foundation

func testDiarizationBackendPreferences() {
    func makeDefaults() -> (UserDefaults, String) {
        let suiteName = "DiarizationBackendPreferencesTests-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defaults.removePersistentDomain(forName: suiteName)
        return (defaults, suiteName)
    }
    let envKey = "TRANSCRIPTED_DIARIZATION_BACKEND"

    runSuite("Diarization backend defaults to pyannote") {
        let (d, s) = makeDefaults(); defer { d.removePersistentDomain(forName: s) }
        assertEqual(DiarizationBackendPreferences.defaultChoice.rawValue, "pyannote", "default stays pyannote (unchanged behavior)")
        assertEqual(DiarizationBackendPreferences.effectiveChoice(userDefaults: d, environment: [:]).rawValue, "pyannote", "no env, no UD -> default")
        assertEqual(DiarizationBackendPreferences.envKey, envKey, "env key is the documented one")
        assertEqual(DiarizationBackendPreferences.preferenceKey, "diarization-backend-preference", "defaults key is the documented one")
    }

    runSuite("Diarization backend honors the environment override") {
        let (d, s) = makeDefaults(); defer { d.removePersistentDomain(forName: s) }
        assertEqual(DiarizationBackendPreferences.effectiveChoice(userDefaults: d, environment: [envKey: "nemotron"]).rawValue, "nemotron", "env nemotron")
        assertEqual(DiarizationBackendPreferences.effectiveChoice(userDefaults: d, environment: [envKey: "NEMOTRON"]).rawValue, "nemotron", "uppercase is lowercased")
        assertEqual(DiarizationBackendPreferences.effectiveChoice(userDefaults: d, environment: [envKey: "garbage"]).rawValue, "pyannote", "garbage env -> default")
    }

    runSuite("Diarization backend persistence and env precedence") {
        let (d, s) = makeDefaults(); defer { d.removePersistentDomain(forName: s) }
        DiarizationBackendPreferences.setPreferredChoice(.nemotron, userDefaults: d)
        assertEqual(DiarizationBackendPreferences.preferredChoice(userDefaults: d).rawValue, "nemotron", "persisted preference")
        assertEqual(DiarizationBackendPreferences.effectiveChoice(userDefaults: d, environment: [:]).rawValue, "nemotron", "no env -> UserDefaults wins")
        assertEqual(DiarizationBackendPreferences.effectiveChoice(userDefaults: d, environment: [envKey: "pyannote"]).rawValue, "pyannote", "env overrides UserDefaults")
        d.set("Nemotron", forKey: DiarizationBackendPreferences.preferenceKey)
        assertEqual(DiarizationBackendPreferences.preferredChoice(userDefaults: d).rawValue, "nemotron", "defaults write with capitals still reads")
    }
}
