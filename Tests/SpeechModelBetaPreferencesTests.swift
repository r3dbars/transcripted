import Foundation

func testSpeechModelBetaPreferences() {
    runSuite("SpeechModelBetaPreferences defaults to off") {
        let (defaults, suiteName) = makeSpeechModelBetaDefaults()
        defer { defaults.removePersistentDomain(forName: suiteName) }

        assertFalse(
            SpeechModelBetaPreferences.nemotronBetaEnabled(userDefaults: defaults),
            "the Nemotron streaming model beta should be opt-in"
        )
    }

    runSuite("SpeechModelBetaPreferences persists enabled state") {
        let (defaults, suiteName) = makeSpeechModelBetaDefaults()
        defer { defaults.removePersistentDomain(forName: suiteName) }

        SpeechModelBetaPreferences.setNemotronBetaEnabled(true, userDefaults: defaults)
        assertTrue(
            SpeechModelBetaPreferences.nemotronBetaEnabled(userDefaults: defaults),
            "the Nemotron beta should read explicit on state"
        )

        SpeechModelBetaPreferences.setNemotronBetaEnabled(false, userDefaults: defaults)
        assertFalse(
            SpeechModelBetaPreferences.nemotronBetaEnabled(userDefaults: defaults),
            "the Nemotron beta should read explicit off state"
        )
    }

    runSuite("SpeechModelBetaPreferences keeps the storage key stable") {
        assertEqual(
            SpeechModelBetaPreferences.nemotronEnabledKey,
            "speech-nemotron-beta-enabled",
            "storage key should not drift across updates"
        )
    }

    runSuite("SpeechModelBetaPreferences posts a change notification") {
        let (defaults, suiteName) = makeSpeechModelBetaDefaults()
        defer { defaults.removePersistentDomain(forName: suiteName) }

        assertEqual(
            Notification.Name.speechModelBetaPreferencesDidChange.rawValue,
            "speechModelBetaPreferencesDidChange",
            "notification name is the contract between the Beta toggle and STTRouter"
        )

        var received = 0
        let observer = NotificationCenter.default.addObserver(
            forName: .speechModelBetaPreferencesDidChange,
            object: nil,
            queue: nil
        ) { _ in
            received += 1
        }
        defer { NotificationCenter.default.removeObserver(observer) }

        SpeechModelBetaPreferences.setNemotronBetaEnabled(true, userDefaults: defaults)
        assertEqual(received, 1, "toggling the beta flag should post exactly one change notification")
    }
}

private func makeSpeechModelBetaDefaults() -> (UserDefaults, String) {
    let suiteName = "SpeechModelBetaPreferencesTests-\(UUID().uuidString)"
    let defaults = UserDefaults(suiteName: suiteName)!
    defaults.removePersistentDomain(forName: suiteName)
    return (defaults, suiteName)
}
