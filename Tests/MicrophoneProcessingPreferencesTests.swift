import Foundation

func testMicrophoneProcessingPreferences() {
    runSuite("MicrophoneProcessingPreferences defaults to software autogain") {
        let (defaults, suiteName) = makeMicrophoneProcessingDefaults()
        defer { defaults.removePersistentDomain(forName: suiteName) }

        assertEqual(
            MicrophoneProcessingPreferences.mode(userDefaults: defaults),
            .softwareAGC,
            "Default mode should keep the existing meeting quiet-mic recovery behavior"
        )
        assertEqual(
            MicrophoneProcessingPreferences.isVoiceProcessingEnabled(userDefaults: defaults),
            false,
            "VPIO toggle should default to false so existing users land on no-Zoom-ducking behavior"
        )
        assertEqual(
            MicrophoneProcessingPreferences.isSoftwareAutogainEnabled(userDefaults: defaults),
            true,
            "Software autogain should remain the default for existing users"
        )
    }

    runSuite("MicrophoneProcessingPreferences persists raw off mode") {
        let (defaults, suiteName) = makeMicrophoneProcessingDefaults()
        defer { defaults.removePersistentDomain(forName: suiteName) }

        MicrophoneProcessingPreferences.setMode(.none, userDefaults: defaults)

        assertEqual(
            MicrophoneProcessingPreferences.mode(userDefaults: defaults),
            .none,
            "Raw/off mode should persist through the injected defaults"
        )
        assertEqual(
            MicrophoneProcessingPreferences.isSoftwareAutogainEnabled(userDefaults: defaults),
            false,
            "Raw/off mode should disable Transcripted software AGC"
        )
        assertEqual(
            MicrophoneProcessingPreferences.isVoiceProcessingEnabled(userDefaults: defaults),
            false,
            "Raw/off mode should not arm Apple voice processing"
        )
    }

    runSuite("MicrophoneProcessingPreferences explains raw input for tuned USB mics") {
        assertTrue(
            MicrophoneProcessingMode.none.title.contains("no Transcripted gain"),
            "Raw/off picker title should explain that Transcripted gain is off"
        )
        assertTrue(
            MicrophoneProcessingMode.none.detail.contains("without software autogain"),
            "Raw/off help text should answer whether Transcripted applies software autogain"
        )
        assertTrue(
            MicrophoneProcessingMode.none.detail.contains("Blue Yeti"),
            "Raw/off help text should name tuned USB mics like Stephen's Blue Yeti"
        )
        assertTrue(
            MicrophoneProcessingMode.none.detail.contains("physical gain controls the level"),
            "Raw/off help text should make the user's hardware gain the control point"
        )
        assertTrue(
            MicrophoneProcessingMode.none.detail.contains("microphone.m4a"),
            "Raw/off help text should tie the setting to the saved mic track users inspect"
        )
    }

    runSuite("MicrophoneProcessingPreferences persists Apple voice processing mode") {
        let (defaults, suiteName) = makeMicrophoneProcessingDefaults()
        defer { defaults.removePersistentDomain(forName: suiteName) }

        MicrophoneProcessingPreferences.setMode(.appleVoiceProcessing, userDefaults: defaults)

        assertEqual(
            MicrophoneProcessingPreferences.isVoiceProcessingEnabled(userDefaults: defaults),
            true,
            "Apple voice processing mode should arm VPIO"
        )
        assertEqual(
            MicrophoneProcessingPreferences.isSoftwareAutogainEnabled(userDefaults: defaults),
            false,
            "Apple voice processing should not also run Transcripted software AGC"
        )
    }

    runSuite("MicrophoneProcessingPreferences legacy toggle maps to modes") {
        let (defaults, suiteName) = makeMicrophoneProcessingDefaults()
        defer { defaults.removePersistentDomain(forName: suiteName) }

        defaults.set(true, forKey: MicrophoneProcessingPreferences.voiceProcessingEnabledKey)

        assertEqual(
            MicrophoneProcessingPreferences.mode(userDefaults: defaults),
            .appleVoiceProcessing,
            "Users who already opted into VPIO should keep that behavior"
        )

        MicrophoneProcessingPreferences.setVoiceProcessingEnabled(false, userDefaults: defaults)

        assertEqual(
            MicrophoneProcessingPreferences.mode(userDefaults: defaults),
            .softwareAGC,
            "The compatibility setter should preserve the old false == default software AGC meaning"
        )
    }

    runSuite("MicrophoneProcessingPreferences explicit mode wins over legacy toggle") {
        let (defaults, suiteName) = makeMicrophoneProcessingDefaults()
        defer { defaults.removePersistentDomain(forName: suiteName) }

        defaults.set(true, forKey: MicrophoneProcessingPreferences.voiceProcessingEnabledKey)
        MicrophoneProcessingPreferences.setMode(.none, userDefaults: defaults)

        assertEqual(
            MicrophoneProcessingPreferences.mode(userDefaults: defaults),
            .none,
            "Once the new mode key exists it should be the source of truth"
        )
    }

    runSuite("MicrophoneProcessingPreferences uses stable storage keys") {
        // Lock the on-disk key so future refactors don't silently invalidate
        // existing users' preferences.
        assertEqual(
            MicrophoneProcessingPreferences.modeKey,
            "meeting-mic-processing-mode",
            "Mode storage key must remain stable across releases"
        )
        assertEqual(
            MicrophoneProcessingPreferences.voiceProcessingEnabledKey,
            "meeting-mic-voice-processing-enabled",
            "Legacy VPIO storage key must remain readable across releases"
        )
    }
}

private func makeMicrophoneProcessingDefaults() -> (UserDefaults, String) {
    let suiteName = "MicrophoneProcessingPreferencesTests-\(UUID().uuidString)"
    let defaults = UserDefaults(suiteName: suiteName)!
    defaults.removePersistentDomain(forName: suiteName)
    return (defaults, suiteName)
}
