import Foundation

func testTranscriptionLanguagePreferences() {
    runSuite("Meeting language defaults to Auto without persisting or changing the model") {
        withLanguageTestDefaults { defaults in
            let before = defaults.dictionaryRepresentation()
            assertEqual(TranscriptionLanguagePreferences.preferredLanguageCode(userDefaults: defaults), "auto")
            for model in TranscriptionModelChoice.allCases {
                assertEqual(TranscriptionLanguagePreferences.effectiveLanguageCode(for: model, userDefaults: defaults), "auto")
            }
            assertNil(defaults.object(forKey: TranscriptionLanguagePreferences.preferenceKey))
            assertTrue(NSDictionary(dictionary: before).isEqual(to: defaults.dictionaryRepresentation()))
        }
    }

    runSuite("Meeting language stores Finnish and restores it when returning to Whisper") {
        withLanguageTestDefaults { defaults in
            let modelBefore = TranscriptionModelPreferences.preferredModel(userDefaults: defaults)
            assertTrue(TranscriptionLanguagePreferences.setPreferredLanguageCode("fi", userDefaults: defaults))
            assertEqual(defaults.string(forKey: TranscriptionLanguagePreferences.preferenceKey), "fi")
            assertEqual(TranscriptionLanguagePreferences.preferredLanguageCode(userDefaults: defaults), "fi")
            assertEqual(TranscriptionModelPreferences.preferredModel(userDefaults: defaults), modelBefore)
            for model in TranscriptionModelChoice.allCases {
                assertEqual(
                    TranscriptionLanguagePreferences.effectiveLanguageCode(for: model, userDefaults: defaults),
                    model.isWhisper ? "fi" : "auto"
                )
                assertEqual(TranscriptionLanguagePreferences.preferredLanguageCode(userDefaults: defaults), "fi")
            }
            assertEqual(
                TranscriptionLanguagePreferences.effectiveLanguageCode(for: .whisperLargeV3, userDefaults: defaults),
                "fi"
            )
            assertEqual(TranscriptionLanguagePreferences.displayName(for: "fi"), "Finnish")
        }
    }

    runSuite("Meeting language catalog has one readable name per pinned Whisper code") {
        let languages = TranscriptionLanguagePreferences.supportedLanguages
        assertEqual(languages.count, 100)
        assertEqual(Set(languages.map(\.code)).count, languages.count)
        assertEqual(Set(languages.map(\.code)), TranscriptionLanguageSelection.supportedCodes,
                    "The UI must advertise exactly the Core language catalog")
        assertEqual(Set(languages.map(\.title)).count, languages.count)
        for language in languages {
            assertEqual(language.id, language.code)
            assertTrue(language.title.count > language.code.count)
            assertEqual(TranscriptionLanguagePreferences.displayName(for: language.code), language.title)
            assertTrue(TranscriptionLanguagePreferences.isSupportedPreference(language.code))
        }
        assertFalse(languages.contains { $0.code == "auto" })
        assertEqual(TranscriptionLanguagePreferences.displayName(for: "auto"), "Auto")
    }

    runSuite("Every advertised meeting language can be persisted and used by Whisper") {
        withLanguageTestDefaults { defaults in
            for language in TranscriptionLanguagePreferences.supportedLanguages {
                assertTrue(TranscriptionLanguagePreferences.setPreferredLanguageCode(language.code, userDefaults: defaults))
                assertEqual(TranscriptionLanguagePreferences.preferredLanguageCode(userDefaults: defaults), language.code)
                assertEqual(
                    TranscriptionLanguagePreferences.effectiveLanguageCode(for: .whisperLargeV3Turbo, userDefaults: defaults),
                    language.code
                )
            }
        }
    }

    runSuite("Unknown meeting language preferences fall back safely without rewriting storage") {
        withLanguageTestDefaults { defaults in
            for invalid in ["", "FI", "en-US", "Finnish", "not-a-language", " fi "] {
                defaults.set(invalid, forKey: TranscriptionLanguagePreferences.preferenceKey)
                assertEqual(TranscriptionLanguagePreferences.preferredLanguageCode(userDefaults: defaults), "auto")
                assertEqual(
                    TranscriptionLanguagePreferences.effectiveLanguageCode(for: .whisperLargeV3, userDefaults: defaults),
                    "auto"
                )
                assertEqual(defaults.string(forKey: TranscriptionLanguagePreferences.preferenceKey), invalid)
                assertFalse(TranscriptionLanguagePreferences.isSupportedPreference(invalid))
                assertEqual(TranscriptionLanguagePreferences.displayName(for: invalid), "Auto")
            }
        }
    }

    runSuite("Invalid selection cannot overwrite a saved meeting language") {
        withLanguageTestDefaults { defaults in
            TranscriptionLanguagePreferences.setPreferredLanguageCode("fi", userDefaults: defaults)
            assertFalse(TranscriptionLanguagePreferences.setPreferredLanguageCode("not-a-language", userDefaults: defaults))
            assertEqual(TranscriptionLanguagePreferences.preferredLanguageCode(userDefaults: defaults), "fi")
            assertTrue(TranscriptionLanguagePreferences.setPreferredLanguageCode("auto", userDefaults: defaults))
            assertEqual(TranscriptionLanguagePreferences.preferredLanguageCode(userDefaults: defaults), "auto")
        }
    }

    runSuite("Meeting language snapshot remains a value when future preferences change") {
        withLanguageTestDefaults { defaults in
            TranscriptionLanguagePreferences.setPreferredLanguageCode("fi", userDefaults: defaults)
            let snapshot = TranscriptionLanguagePreferences.effectiveLanguageCode(for: .whisperLargeV3, userDefaults: defaults)
            TranscriptionLanguagePreferences.setPreferredLanguageCode("de", userDefaults: defaults)
            assertEqual(snapshot, "fi")
            assertEqual(
                TranscriptionLanguagePreferences.effectiveLanguageCode(for: .whisperLargeV3, userDefaults: defaults),
                "de"
            )
        }
    }
}

private func withLanguageTestDefaults(_ test: (UserDefaults) -> Void) {
    let name = "TranscriptionLanguagePreferencesTests.\(UUID().uuidString)"
    let defaults = UserDefaults(suiteName: name)!
    defer { defaults.removePersistentDomain(forName: name) }
    test(defaults)
}
