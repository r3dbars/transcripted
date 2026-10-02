import Foundation

func testNotchIslandPreferences() {
    runSuite("NotchIslandPreferences keeps the island out of screen sharing unless turned on") {
        let (defaults, suiteName) = makeNotchIslandPreferencesDefaults()
        defer { defaults.removePersistentDomain(forName: suiteName) }

        assertFalse(
            NotchIslandPreferences.visibleInScreenSharing(userDefaults: defaults),
            "a shared screen must not show live dictation by default"
        )
        NotchIslandPreferences.setVisibleInScreenSharing(true, userDefaults: defaults)
        assertTrue(NotchIslandPreferences.visibleInScreenSharing(userDefaults: defaults), "turning it on persists")
        assertEqual(
            NotchIslandPreferences.visibleInScreenSharingKey,
            "notchIslandVisibleInScreenSharing",
            "the Settings toggle and the island read the same key"
        )
    }

    runSuite("NotchIslandPreferences keeps the live transcript off until turned on") {
        let (defaults, suiteName) = makeNotchIslandPreferencesDefaults()
        defer { defaults.removePersistentDomain(forName: suiteName) }

        assertFalse(
            NotchIslandPreferences.showsLiveTranscript(userDefaults: defaults),
            "meetings don't run live transcription unless asked"
        )
        NotchIslandPreferences.setShowsLiveTranscript(true, userDefaults: defaults)
        assertTrue(NotchIslandPreferences.showsLiveTranscript(userDefaults: defaults), "turning it on persists")
    }
}

private func makeNotchIslandPreferencesDefaults() -> (UserDefaults, String) {
    let suiteName = "NotchIslandPreferencesTests-\(UUID().uuidString)"
    let defaults = UserDefaults(suiteName: suiteName)!
    defaults.removePersistentDomain(forName: suiteName)
    return (defaults, suiteName)
}
