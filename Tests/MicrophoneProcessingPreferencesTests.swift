import Foundation

func testMicrophoneProcessingPreferences() {
    runSuite("MicrophoneProcessingPreferences defaults to false") {
        let (defaults, suiteName) = makeMicrophoneProcessingDefaults()
        defer { defaults.removePersistentDomain(forName: suiteName) }

        assertEqual(
            MicrophoneProcessingPreferences.isVoiceProcessingEnabled(userDefaults: defaults),
            false,
            "VPIO toggle should default to false so existing users land on no-Zoom-ducking behavior"
        )
    }

    runSuite("MicrophoneProcessingPreferences persists enabled toggle") {
        let (defaults, suiteName) = makeMicrophoneProcessingDefaults()
        defer { defaults.removePersistentDomain(forName: suiteName) }

        MicrophoneProcessingPreferences.setVoiceProcessingEnabled(true, userDefaults: defaults)

        assertEqual(
            MicrophoneProcessingPreferences.isVoiceProcessingEnabled(userDefaults: defaults),
            true,
            "Enabled state should persist through the injected defaults"
        )
    }

    runSuite("MicrophoneProcessingPreferences toggle round-trips back to false") {
        let (defaults, suiteName) = makeMicrophoneProcessingDefaults()
        defer { defaults.removePersistentDomain(forName: suiteName) }

        MicrophoneProcessingPreferences.setVoiceProcessingEnabled(true, userDefaults: defaults)
        MicrophoneProcessingPreferences.setVoiceProcessingEnabled(false, userDefaults: defaults)

        assertEqual(
            MicrophoneProcessingPreferences.isVoiceProcessingEnabled(userDefaults: defaults),
            false,
            "Disabled state should persist after toggling back"
        )
    }

    runSuite("MicrophoneProcessingPreferences uses a stable storage key") {
        // Lock the on-disk key so future refactors don't silently invalidate
        // existing users' preferences.
        assertEqual(
            MicrophoneProcessingPreferences.voiceProcessingEnabledKey,
            "meeting-mic-voice-processing-enabled",
            "Storage key must remain stable across releases"
        )
    }
}

private func makeMicrophoneProcessingDefaults() -> (UserDefaults, String) {
    let suiteName = "MicrophoneProcessingPreferencesTests-\(UUID().uuidString)"
    let defaults = UserDefaults(suiteName: suiteName)!
    defaults.removePersistentDomain(forName: suiteName)
    return (defaults, suiteName)
}
