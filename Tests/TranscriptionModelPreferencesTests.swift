import Foundation

func testTranscriptionModelPreferences() {
    runSuite("Parakeet v2 preference persists without changing the default") {
        let name = "TranscriptionModelPreferencesTests.v2.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: name)!
        defer { defaults.removePersistentDomain(forName: name) }
        TranscriptionModelPreferences.setPreferredModel(.parakeetTDTv2, userDefaults: defaults)
        assertEqual(TranscriptionModelPreferences.preferredModel(userDefaults: defaults), .parakeetTDTv2)
        assertEqual(TranscriptionModelPreferences.defaultModel, .parakeetTDTv3)
        assertEqual(TranscriptionModelChoice.allCases.count, 6)
        assertEqual(TranscriptionModelChoice.parakeetTDTv2.parakeetVariant, .v2)
        assertEqual(TranscriptionModelChoice.parakeetTDTv3.parakeetVariant, .v3)
        assertEqual(TranscriptionModelChoice.parakeetUltraExperimental.parakeetVariant, .ultra)
        assertNil(TranscriptionModelChoice.whisperLargeV3.parakeetVariant)
    }

    runSuite("Parakeet Ultra is an experimental v3-shaped model that is never downloaded") {
        let ultra = ParakeetModelVariant.ultra
        assertTrue(ultra.isLocalInstallOnly)
        assertFalse(ParakeetModelVariant.v2.isLocalInstallOnly)
        assertFalse(ParakeetModelVariant.v3.isLocalInstallOnly)
        assertEqual(ultra.jointModelName, ParakeetModelVariant.v3.jointModelName)
        assertEqual(ultra.requiredModelDirectoryNames, ParakeetModelVariant.v3.requiredModelDirectoryNames)
        assertEqual(ultra.requiredFileNames, ParakeetModelVariant.v3.requiredFileNames + ["transcripted-model.json"],
            "an Ultra folder without the install marker is not Ultra")
        // FluidAudio resolves <parent>/parakeet-tdt-0.6b-v3, so the leaf must
        // keep that name while the parent carries Ultra's identity.
        assertEqual(ultra.localInstallRelativePath, "parakeet-ultra/parakeet-tdt-0.6b-v3")
        assertNil(ParakeetModelVariant.v3.localInstallRelativePath)
        assertNil(ParakeetModelVariant.v2.localInstallRelativePath)
        assertEqual(TranscriptionModelPreferences.defaultModel, .parakeetTDTv3, "Ultra is opt-in only")
    }

    runSuite("The model picker hides Ultra until it is installed") {
        let installed: (ParakeetModelVariant) -> Bool = { _ in true }
        let missing: (ParakeetModelVariant) -> Bool = { _ in false }
        for model in TranscriptionModelChoice.allCases where model != .parakeetUltraExperimental {
            assertTrue(TranscriptionModelVisibilityPolicy.isVisible(
                model, selectedModel: .parakeetTDTv3, isLocallyInstalled: missing
            ), "\(model.rawValue) is always offered")
        }
        assertFalse(TranscriptionModelVisibilityPolicy.isVisible(
            .parakeetUltraExperimental, selectedModel: .parakeetTDTv3, isLocallyInstalled: missing
        ))
        assertTrue(TranscriptionModelVisibilityPolicy.isVisible(
            .parakeetUltraExperimental, selectedModel: .parakeetTDTv3, isLocallyInstalled: installed
        ))
        assertTrue(TranscriptionModelVisibilityPolicy.isVisible(
            .parakeetUltraExperimental, selectedModel: .parakeetUltraExperimental, isLocallyInstalled: missing
        ), "a selected model stays listed so the picker never goes blank")
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

    runSuite("TranscriptionModelPreferences stores an Apple Speech preference") {
        let suiteName = "TranscriptionModelPreferencesTests.apple.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }

        TranscriptionModelPreferences.setPreferredModel(.appleSpeech, userDefaults: defaults)

        assertEqual(TranscriptionModelPreferences.preferredModel(userDefaults: defaults), .appleSpeech)
        assertEqual(defaults.string(forKey: "transcription-model-preference"), "apple-speech")
        assertEqual(TranscriptionModelPreferences.defaultModel, .parakeetTDTv3,
                    "adding Apple Speech must not change the default engine")
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
