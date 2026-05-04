import Foundation

func testAudioStoragePreferences() {
    runSuite("AudioStoragePreferences defaults to keeping compressed audio") {
        let (defaults, suiteName) = makeAudioStorageDefaults()
        defer { UserDefaults().removePersistentDomain(forName: suiteName) }

        assertEqual(
            AudioStoragePreferences.deleteAudioAfter(userDefaults: defaults),
            .never,
            "audio retention should default to never deleting retained compressed audio"
        )
    }

    runSuite("AudioStoragePreferences persists delete-after window") {
        let (defaults, suiteName) = makeAudioStorageDefaults()
        defer { UserDefaults().removePersistentDomain(forName: suiteName) }

        AudioStoragePreferences.setDeleteAudioAfter(.sevenDays, userDefaults: defaults)

        assertEqual(
            AudioStoragePreferences.deleteAudioAfter(userDefaults: defaults),
            .sevenDays,
            "explicit retention window should round-trip"
        )
    }

    runSuite("AudioStoragePreferences falls back from unknown values") {
        let (defaults, suiteName) = makeAudioStorageDefaults()
        defer { UserDefaults().removePersistentDomain(forName: suiteName) }

        defaults.set("soonish", forKey: AudioStoragePreferences.deleteAudioAfterKey)

        assertEqual(
            AudioStoragePreferences.deleteAudioAfter(userDefaults: defaults),
            .never,
            "unknown retention values should fail closed to keeping audio"
        )
    }
}

private func makeAudioStorageDefaults() -> (UserDefaults, String) {
    let suiteName = "AudioStoragePreferencesTests-\(UUID().uuidString)"
    let defaults = UserDefaults(suiteName: suiteName)!
    defaults.removePersistentDomain(forName: suiteName)
    return (defaults, suiteName)
}
