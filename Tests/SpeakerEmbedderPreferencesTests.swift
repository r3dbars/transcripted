import Foundation

func testSpeakerEmbedderPreferences() {
    func makeDefaults() -> (UserDefaults, String) {
        let suiteName = "SpeakerEmbedderPreferencesTests-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defaults.removePersistentDomain(forName: suiteName)
        return (defaults, suiteName)
    }
    let envKey = "TRANSCRIPTED_SPEAKER_EMBEDDER"

    runSuite("effectiveChoice honors the environment override") {
        let (d, s) = makeDefaults(); defer { d.removePersistentDomain(forName: s) }
        assertEqual(SpeakerEmbedderPreferences.effectiveChoice(userDefaults: d, environment: [envKey: "eres2net"]).rawValue, "eres2net", "env eres2net")
        assertEqual(SpeakerEmbedderPreferences.effectiveChoice(userDefaults: d, environment: [envKey: "wespeaker"]).rawValue, "wespeaker", "env wespeaker")
        assertEqual(SpeakerEmbedderPreferences.effectiveChoice(userDefaults: d, environment: [envKey: "ERES2NET"]).rawValue, "eres2net", "uppercase is lowercased")
    }

    runSuite("effectiveChoice falls back on invalid or empty input") {
        let (d, s) = makeDefaults(); defer { d.removePersistentDomain(forName: s) }
        assertEqual(SpeakerEmbedderPreferences.effectiveChoice(userDefaults: d, environment: [envKey: "garbage"]).rawValue, "wespeaker", "garbage env -> default")
        assertEqual(SpeakerEmbedderPreferences.effectiveChoice(userDefaults: d, environment: [:]).rawValue, "wespeaker", "no env, no UD -> default")
        assertEqual(SpeakerEmbedderPreferences.defaultChoice.rawValue, "wespeaker", "default stays WeSpeaker (unchanged behavior)")
    }

    runSuite("UserDefaults persistence and env precedence") {
        let (d, s) = makeDefaults(); defer { d.removePersistentDomain(forName: s) }
        SpeakerEmbedderPreferences.setPreferredChoice(.eRes2Net, userDefaults: d)
        assertEqual(SpeakerEmbedderPreferences.preferredChoice(userDefaults: d).rawValue, "eres2net", "persisted preference")
        assertEqual(SpeakerEmbedderPreferences.effectiveChoice(userDefaults: d, environment: [:]).rawValue, "eres2net", "no env -> UserDefaults wins")
        assertEqual(SpeakerEmbedderPreferences.effectiveChoice(userDefaults: d, environment: [envKey: "wespeaker"]).rawValue, "wespeaker", "env overrides UserDefaults")
        assertEqual(SpeakerEmbedderPreferences.preferredChoice(userDefaults: d).rawValue, "eres2net", "preferredChoice ignores env")
    }

    // Regression guard for the load-vs-file-existence bug: the speaker DB filename
    // is keyed on the *loaded* embedder identifier. A nil identifier — which is
    // what a present-but-unloadable ERes2Net model produces — must map to the
    // default speakers.sqlite so 256-d WeSpeaker vectors can never land in the
    // 192-d ERes2Net database.
    runSuite("speakerDBFileName keeps per-model databases dimension-isolated") {
        assertEqual(SpeakerEmbedderPreferences.speakerDBFileName(forEmbedderIdentifier: nil), "speakers.sqlite", "nil id (incl. load-failed ERes2Net) -> default db")
        assertEqual(SpeakerEmbedderPreferences.speakerDBFileName(forEmbedderIdentifier: ""), "speakers.sqlite", "empty id -> default db")
        assertEqual(SpeakerEmbedderPreferences.speakerDBFileName(forEmbedderIdentifier: "eres2net"), "speakers_eres2net.sqlite", "eres2net id -> eres2net db")
    }
}
