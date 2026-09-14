import Foundation

func testTranscriptionModelPreferences() {
    runSuite("Parakeet v2 preference persists without changing the default") {
        let name = "TranscriptionModelPreferencesTests.v2.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: name)!
        defer { defaults.removePersistentDomain(forName: name) }
        TranscriptionModelPreferences.setPreferredModel(.parakeetTDTv2, userDefaults: defaults)
        assertEqual(TranscriptionModelPreferences.preferredModel(userDefaults: defaults), .parakeetTDTv2)
        assertEqual(TranscriptionModelPreferences.defaultModel, .parakeetTDTv3)
        assertEqual(TranscriptionModelChoice.allCases.count, 4)
        assertEqual(TranscriptionModelChoice.parakeetTDTv2.parakeetVariant, .v2)
        assertEqual(TranscriptionModelChoice.parakeetTDTv3.parakeetVariant, .v3)
        assertNil(TranscriptionModelChoice.whisperLargeV3.parakeetVariant)
    }

    runSuite("TranscriptionModelPreferences defaults to Parakeet") {
        let suiteName = "TranscriptionModelPreferencesTests.default.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }

        assertEqual(
            TranscriptionModelPreferences.preferredModel(userDefaults: defaults),
            .parakeetTDTv3,
            "Parakeet should be the out-of-box preferred model"
        )
    }

    runSuite("TranscriptionModelPreferences stores a Whisper preference") {
        let suiteName = "TranscriptionModelPreferencesTests.whisper.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }

        TranscriptionModelPreferences.setPreferredModel(.whisperLargeV3Turbo, userDefaults: defaults)

        assertEqual(
            TranscriptionModelPreferences.preferredModel(userDefaults: defaults),
            .whisperLargeV3Turbo,
            "advanced users should be able to save a Whisper preference"
        )
    }

    runSuite("TranscriptionModelPreferences ignores unknown saved values") {
        let suiteName = "TranscriptionModelPreferencesTests.unknown.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }

        defaults.set("not-a-real-model", forKey: "transcription-model-preference")

        assertEqual(
            TranscriptionModelPreferences.preferredModel(userDefaults: defaults),
            .parakeetTDTv3,
            "unknown saved model identifiers should fall back to Parakeet"
        )
    }

    runSuite("TranscriptionModelPreferences self-heals retired saved models to Parakeet") {
        // The Nemotron streaming beta was removed; installs that still have its
        // rawValue persisted must silently fall back to the default model.
        let suiteName = "TranscriptionModelPreferencesTests.retired.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }

        defaults.set("nemotron-streaming-0.6b", forKey: "transcription-model-preference")

        assertEqual(
            TranscriptionModelPreferences.preferredModel(userDefaults: defaults),
            .parakeetTDTv3,
            "the retired Nemotron rawValue should fall back to Parakeet"
        )
    }
}
