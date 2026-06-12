import Foundation

func testLiveMeetingCodexPreferences() {
    runSuite("LiveMeetingCodexPreferences — live meetings stays opt-in by default") {
        let (defaults, suiteName) = makeLiveMeetingCodexDefaults()
        defer { UserDefaults().removePersistentDomain(forName: suiteName) }

        assertFalse(
            LiveMeetingCodexPreferences.isEnabled(userDefaults: defaults),
            "the live meeting sidecar must stay off until the user opts in"
        )

        LiveMeetingCodexPreferences.setEnabled(true, userDefaults: defaults)
        assertTrue(LiveMeetingCodexPreferences.isEnabled(userDefaults: defaults))
    }

    runSuite("LiveMeetingCodexPreferences — drawer defaults open and remembers the choice") {
        let (defaults, suiteName) = makeLiveMeetingCodexDefaults()
        defer { UserDefaults().removePersistentDomain(forName: suiteName) }

        assertTrue(
            LiveMeetingCodexPreferences.isDrawerOpenPreferred(userDefaults: defaults),
            "users who turned live meetings on should see the transcript without an extra click"
        )

        LiveMeetingCodexPreferences.setDrawerOpenPreferred(false, userDefaults: defaults)
        assertFalse(
            LiveMeetingCodexPreferences.isDrawerOpenPreferred(userDefaults: defaults),
            "an explicit hide should stick for the next meeting"
        )

        LiveMeetingCodexPreferences.setDrawerOpenPreferred(true, userDefaults: defaults)
        assertTrue(LiveMeetingCodexPreferences.isDrawerOpenPreferred(userDefaults: defaults))
    }

    runSuite("LiveMeetingCodexPreferences — drawer height defaults, clamps, and persists") {
        let (defaults, suiteName) = makeLiveMeetingCodexDefaults()
        defer { UserDefaults().removePersistentDomain(forName: suiteName) }

        assertEqual(
            LiveMeetingCodexPreferences.preferredDrawerHeight(userDefaults: defaults),
            LiveMeetingCodexPreferences.defaultDrawerHeight,
            "no stored value should fall back to the default drawer height"
        )

        LiveMeetingCodexPreferences.setPreferredDrawerHeight(320, userDefaults: defaults)
        assertEqual(LiveMeetingCodexPreferences.preferredDrawerHeight(userDefaults: defaults), 320)

        LiveMeetingCodexPreferences.setPreferredDrawerHeight(40, userDefaults: defaults)
        assertEqual(
            LiveMeetingCodexPreferences.preferredDrawerHeight(userDefaults: defaults),
            LiveMeetingCodexPreferences.minimumDrawerHeight,
            "tiny heights should clamp up so the drawer stays usable"
        )

        LiveMeetingCodexPreferences.setPreferredDrawerHeight(2000, userDefaults: defaults)
        assertEqual(
            LiveMeetingCodexPreferences.preferredDrawerHeight(userDefaults: defaults),
            LiveMeetingCodexPreferences.maximumDrawerHeight,
            "huge heights should clamp down so the panel stays a panel"
        )
    }

    runSuite("LiveMeetingCodexPreferences — clamp helper bounds") {
        assertEqual(
            LiveMeetingCodexPreferences.clampedDrawerHeight(0),
            LiveMeetingCodexPreferences.minimumDrawerHeight
        )
        assertEqual(LiveMeetingCodexPreferences.clampedDrawerHeight(300), 300)
        assertEqual(
            LiveMeetingCodexPreferences.clampedDrawerHeight(.greatestFiniteMagnitude),
            LiveMeetingCodexPreferences.maximumDrawerHeight
        )
    }
}

private func makeLiveMeetingCodexDefaults() -> (UserDefaults, String) {
    let suiteName = "LiveMeetingCodexPreferencesTests-\(UUID().uuidString)"
    let defaults = UserDefaults(suiteName: suiteName)!
    defaults.removePersistentDomain(forName: suiteName)
    return (defaults, suiteName)
}
