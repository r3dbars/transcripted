import Foundation

func testTranscriptionModelPreferences() {
    runSuite("TranscriptionModelPreferences defaults to Parakeet") {
        let suiteName = "TranscriptionModelPreferencesTests.default.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }

        assertEqual(
            TranscriptionModelPreferences.preferredModel(userDefaults: defaults),
            .parakeetTDTv3,
            "Parakeet should be the out-of-box preferred model"
        )
        assertEqual(
            TranscriptionModelPreferences.effectiveModel(userDefaults: defaults),
            .parakeetTDTv3,
            "Parakeet should be the out-of-box effective runtime"
        )
    }

    runSuite("TranscriptionModelPreferences stores Whisper preference as the effective runtime") {
        let suiteName = "TranscriptionModelPreferencesTests.whisper.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }

        TranscriptionModelPreferences.setPreferredModel(.whisperLargeV3Turbo, userDefaults: defaults)

        assertEqual(
            TranscriptionModelPreferences.preferredModel(userDefaults: defaults),
            .whisperLargeV3Turbo,
            "advanced users should be able to save a Whisper preference"
        )
        assertEqual(
            TranscriptionModelPreferences.effectiveModel(userDefaults: defaults),
            .whisperLargeV3Turbo,
            "Whisper should become the effective runtime once selected"
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
}
