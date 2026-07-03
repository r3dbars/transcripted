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

    runSuite("TranscriptionModelPreferences round-trips the Nemotron rawValue") {
        assertEqual(
            TranscriptionModelChoice.nemotronStreaming.rawValue,
            "nemotron-streaming-0.6b",
            "Nemotron rawValue is persisted; renaming it would orphan saved preferences"
        )
        assertEqual(
            TranscriptionModelChoice(rawValue: "nemotron-streaming-0.6b"),
            .nemotronStreaming,
            "Nemotron rawValue should round-trip through the enum"
        )
    }

    runSuite("TranscriptionModelPreferences falls back to Parakeet while the Nemotron beta is off") {
        let suiteName = "TranscriptionModelPreferencesTests.nemotron.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }

        TranscriptionModelPreferences.setPreferredModel(.nemotronStreaming, userDefaults: defaults)

        assertEqual(
            TranscriptionModelPreferences.preferredModel(userDefaults: defaults),
            .nemotronStreaming,
            "the saved Nemotron preference should survive even while gated"
        )
        assertEqual(
            TranscriptionModelPreferences.effectiveModel(userDefaults: defaults),
            .parakeetTDTv3,
            "with the beta flag off, the effective runtime should self-heal to Parakeet"
        )

        SpeechModelBetaPreferences.setNemotronBetaEnabled(true, userDefaults: defaults)
        assertEqual(
            TranscriptionModelPreferences.effectiveModel(userDefaults: defaults),
            .nemotronStreaming,
            "with the beta flag on, the saved Nemotron preference should become effective"
        )
    }

    runSuite("TranscriptionModelPreferences exposes complete Nemotron metadata") {
        let model = TranscriptionModelChoice.nemotronStreaming

        assertEqual(model.title, "Nemotron Streaming (Beta)", "Nemotron title should flag the beta state")
        assertEqual(model.shortTitle, "Nemotron", "Nemotron short title should stay compact")
        assertFalse(model.summary.isEmpty, "Nemotron summary must be non-empty")
        assertFalse(model.transcriptionEngineDisplayName.isEmpty, "Nemotron engine display name must be non-empty")
        assertEqual(model.approximateDownloadSize, "~600 MB", "Nemotron download size should be surfaced")
        assertEqual(model.engineName, "nemotron", "Nemotron must classify to the nemotron engine path")
        assertEqual(model.transcriptionEngineIdentifier, "nemotron_streaming_local", "Nemotron analytics identifier should stay stable")
        assertFalse(model.isWhisper, "Nemotron must not be classified as a Whisper model")
        assertNil(model.whisperKitModelName, "Nemotron must not request a WhisperKit bundle")
    }
}
