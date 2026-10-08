import Foundation

private struct VoiceprintResolutionTable: Decodable {
    struct Case: Decodable {
        let name: String
        let stored: String?
        let env: String?
        let present: [String]
        let failed: [String]
        let model: String
        let identifier: String?
        let database: String
        let fallback: String?
    }
    let cases: [Case]
}

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
        assertEqual(SpeakerEmbedderChoiceResolution.effectiveChoice(userDefaults: d, environment: [envKey: "eres2net"]).rawValue, "eres2net", "env eres2net")
        assertEqual(SpeakerEmbedderChoiceResolution.effectiveChoice(userDefaults: d, environment: [envKey: "wespeaker"]).rawValue, "wespeaker", "env wespeaker")
        assertEqual(SpeakerEmbedderChoiceResolution.effectiveChoice(userDefaults: d, environment: [envKey: "ERES2NET"]).rawValue, "eres2net", "uppercase is lowercased")
    }

    runSuite("effectiveChoice falls back on invalid or empty input") {
        let (d, s) = makeDefaults(); defer { d.removePersistentDomain(forName: s) }
        assertEqual(SpeakerEmbedderChoiceResolution.effectiveChoice(userDefaults: d, environment: [envKey: "garbage"]).rawValue, "redimnet2", "garbage env -> default")
        assertEqual(SpeakerEmbedderChoiceResolution.effectiveChoice(userDefaults: d, environment: [:]).rawValue, "redimnet2", "no env, no UD -> default")
        assertEqual(SpeakerEmbedderChoiceResolution.defaultChoice.rawValue, "redimnet2", "ReDimNet2 is the default voiceprint")
        assertEqual(SpeakerEmbedderChoiceResolution.effectiveChoice(userDefaults: d, environment: [envKey: "wespeaker"]).rawValue, "wespeaker", "env can still pick the previous model")
    }

    runSuite("UserDefaults persistence and env precedence") {
        let (d, s) = makeDefaults(); defer { d.removePersistentDomain(forName: s) }
        SpeakerEmbedderPreferences.setPreferredChoice(.eRes2Net, userDefaults: d)
        assertEqual(SpeakerEmbedderChoiceResolution.preferredChoice(userDefaults: d).rawValue, "eres2net", "persisted preference")
        assertEqual(SpeakerEmbedderChoiceResolution.effectiveChoice(userDefaults: d, environment: [:]).rawValue, "eres2net", "no env -> UserDefaults wins")
        assertEqual(SpeakerEmbedderChoiceResolution.effectiveChoice(userDefaults: d, environment: [envKey: "wespeaker"]).rawValue, "wespeaker", "env overrides UserDefaults")
        assertEqual(SpeakerEmbedderChoiceResolution.preferredChoice(userDefaults: d).rawValue, "eres2net", "preferredChoice ignores env")
    }

    runSuite("a stored WeSpeaker choice from the old call-matching switch reads as the default") {
        let (d, s) = makeDefaults(); defer { d.removePersistentDomain(forName: s) }
        SpeakerEmbedderPreferences.setPreferredChoice(.weSpeaker, userDefaults: d)
        assertEqual(SpeakerEmbedderChoiceResolution.preferredChoice(userDefaults: d).rawValue, "redimnet2", "stored wespeaker -> default")
        assertEqual(SpeakerEmbedderChoiceResolution.effectiveChoice(userDefaults: d, environment: [:]).rawValue, "redimnet2", "no env -> call-audio model")
        assertEqual(SpeakerEmbedderChoiceResolution.effectiveChoice(userDefaults: d, environment: [envKey: "wespeaker"]).rawValue, "wespeaker", "env can still pick the previous model")
    }

    // Regression guard for the load-vs-file-existence bug: the speaker DB filename
    // is keyed on the *loaded* embedder identifier. A nil identifier — which is
    // what a present-but-unloadable ERes2Net model produces — must map to the
    // default speakers.sqlite so 256-d WeSpeaker vectors can never land in the
    // 192-d ERes2Net database.
    runSuite("speakerDBFileName keeps per-model databases dimension-isolated") {
        assertEqual(SpeakerVoiceprintSelection.databaseFileName(forEmbedderIdentifier: nil), "speakers.sqlite", "nil id (incl. load-failed ERes2Net) -> default db")
        assertEqual(SpeakerVoiceprintSelection.databaseFileName(forEmbedderIdentifier: ""), "speakers.sqlite", "empty id -> default db")
        assertEqual(SpeakerVoiceprintSelection.databaseFileName(forEmbedderIdentifier: "eres2net"), "speakers_eres2net.sqlite", "eres2net id -> eres2net db")
        assertEqual(SpeakerVoiceprintSelection.databaseFileName(forEmbedderIdentifier: "redimnet2-b4"), "speakers_redimnet2-b4.sqlite", "ReDimNet2 gets its own db, never the WeSpeaker one")
    }

    // App side of the shared table (Tests/Fixtures/speaker-voiceprint-resolution.json),
    // composed the way SpeakerEmbedderFactory composes it: stored preference written
    // through Settings' setter, the effective choice, the per-build load-failure
    // memory, then the database filename. The CLI asserts the same rows.
    runSuite("app resolves every row of the shared voiceprint table") {
        let table = loadJSONFixture("Tests/Fixtures/speaker-voiceprint-resolution.json", as: VoiceprintResolutionTable.self)
        assertEqual(SpeakerEmbedderPreferences.preferenceKey, SpeakerVoiceprintSelection.preferenceKey, "Settings writes the key the CLI reads")
        for row in table.cases {
            let (d, s) = makeDefaults(); defer { d.removePersistentDomain(forName: s) }
            if let stored = row.stored {
                if let choice = SpeakerEmbedderChoice(rawValue: stored) {
                    SpeakerEmbedderPreferences.setPreferredChoice(choice, userDefaults: d)
                } else {
                    d.set(stored, forKey: SpeakerEmbedderPreferences.preferenceKey)
                }
            }
            let memory = SpeakerEmbedderLoadFailureMemory(userDefaults: d, buildKey: "100|macOS 26.1")
            for failed in row.failed { memory.recordLoadEnded(failed, loaded: false) }
            let choice = SpeakerEmbedderChoiceResolution.effectiveChoice(
                userDefaults: d, environment: row.env.map { [envKey: $0] } ?? [:]
            )
            let chosenID = choice.voiceprintModel.embedderIdentifier
            let present = row.present.contains(choice.rawValue)
            let identifier = memory.launchModelIdentifier(chosen: chosenID, modelFileIsPresent: present)
            let fallback: String? = (chosenID == nil || identifier != nil) ? nil
                : (present ? "failedToLoadOnThisBuild" : "modelFileMissing")
            assertEqual(choice.rawValue, row.model, "\(row.name): model")
            assertEqual(identifier, row.identifier, "\(row.name): embedder")
            assertEqual(SpeakerVoiceprintSelection.databaseFileName(forEmbedderIdentifier: identifier), row.database, "\(row.name): database")
            assertEqual(fallback, row.fallback, "\(row.name): fallback")
        }
    }
}
