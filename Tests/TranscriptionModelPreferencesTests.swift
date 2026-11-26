import Foundation

func testTranscriptionModelPreferences() {
    runSuite("User-facing STT choices narrow to Parakeet V3 and Whisper Large V3 Turbo") {
        assertEqual(TranscriptionModelPreferences.defaultModel, .parakeetTDTv3)
        assertEqual(TranscriptionModelChoice.allCases, [
            .parakeetTDTv3,
            .whisperLargeV3Turbo,
            .parakeetUltraExperimental,
        ])
        assertEqual(TranscriptionModelChoice.parakeetTDTv3.parakeetVariant, .v3)
        assertEqual(TranscriptionModelChoice.parakeetUltraExperimental.parakeetVariant, .ultra)
        assertNil(TranscriptionModelChoice.whisperLargeV3Turbo.parakeetVariant)

        let visibleWithoutLocalInstall = TranscriptionModelChoice.allCases.filter { model in
            TranscriptionModelVisibilityPolicy.isVisible(
                model,
                selectedModel: .parakeetTDTv3,
                isLocallyInstalled: { _ in false }
            )
        }
        assertEqual(
            visibleWithoutLocalInstall,
            [.parakeetTDTv3, .whisperLargeV3Turbo],
            "normal installs should see strictly 2 choices in the picker"
        )
    }

    runSuite("Parakeet Ultra is an experimental v3-shaped model that is never downloaded") {
        let ultra = ParakeetModelVariant.ultra
        assertTrue(ultra.isLocalInstallOnly)
        assertFalse(ParakeetModelVariant.v3.isLocalInstallOnly)
        assertEqual(ultra.jointModelName, ParakeetModelVariant.v3.jointModelName)
        assertEqual(ultra.requiredModelDirectoryNames, ParakeetModelVariant.v3.requiredModelDirectoryNames)
        assertEqual(ultra.requiredFileNames, ParakeetModelVariant.v3.requiredFileNames + ["transcripted-model.json"],
            "an Ultra folder without the install marker is not Ultra")
        // FluidAudio resolves <parent>/parakeet-tdt-0.6b-v3, so the leaf must
        // keep that name while the parent carries Ultra's identity.
        assertEqual(ultra.localInstallRelativePath, "parakeet-ultra/parakeet-tdt-0.6b-v3")
        assertNil(ParakeetModelVariant.v3.localInstallRelativePath)
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
            "users should be able to save Whisper Large V3 Turbo"
        )
    }

    runSuite("TranscriptionModelPreferences migrates every retired stored model ID to its successor") {
        let suiteName = "TranscriptionModelPreferencesTests.migrate.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let expectedMigrations: [(legacyRawValue: String, expected: TranscriptionModelChoice)] = [
            ("parakeet-tdt-v2", .parakeetTDTv3),
            ("apple-speech", .parakeetTDTv3),
            ("parakeet-ultra", .parakeetTDTv3),
            ("nemotron-streaming-0.6b", .parakeetTDTv3),
            ("whisper-large-v3", .whisperLargeV3Turbo),
        ]

        for (legacyRawValue, expected) in expectedMigrations {
            defaults.set(legacyRawValue, forKey: "transcription-model-preference")
            assertEqual(
                TranscriptionModelPreferences.migratedModel(forStoredRawValue: legacyRawValue),
                expected,
                "legacy rawValue '\(legacyRawValue)' should explicitly map to \(expected.rawValue)"
            )
            assertEqual(
                TranscriptionModelPreferences.preferredModel(userDefaults: defaults),
                expected,
                "stored '\(legacyRawValue)' must seamlessly migrate to \(expected.rawValue)"
            )
        }
    }

    runSuite("TranscriptionModelPreferences ignores unknown saved values") {
        let suiteName = "TranscriptionModelPreferencesTests.unknown.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }

        for invalid in ["not-a-real-model", "", "parakeet", "whisper-large-v3-turbo "] {
            defaults.set(invalid, forKey: "transcription-model-preference")
            assertNil(
                TranscriptionModelPreferences.migratedModel(forStoredRawValue: invalid),
                "unknown stored value '\(invalid)' should not match a migration entry"
            )
            assertEqual(
                TranscriptionModelPreferences.preferredModel(userDefaults: defaults),
                .parakeetTDTv3,
                "unknown saved model identifier '\(invalid)' should fall back to Parakeet V3"
            )
        }
    }
}
