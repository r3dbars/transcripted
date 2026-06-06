import Foundation

func testLocalMeetingSummaryPreferences() {
    runSuite("LocalMeetingSummaryPreferences defaults to off") {
        let (defaults, suiteName) = makeLocalMeetingSummaryDefaults()
        defer { defaults.removePersistentDomain(forName: suiteName) }

        assertFalse(LocalMeetingSummaryPreferences.isEnabled(userDefaults: defaults), "local AI summaries should be opt-in")
    }

    runSuite("LocalMeetingSummaryPreferences persists enabled state") {
        let (defaults, suiteName) = makeLocalMeetingSummaryDefaults()
        defer { defaults.removePersistentDomain(forName: suiteName) }

        LocalMeetingSummaryPreferences.setEnabled(true, userDefaults: defaults)
        assertTrue(LocalMeetingSummaryPreferences.isEnabled(userDefaults: defaults), "summary beta should read explicit on state")

        LocalMeetingSummaryPreferences.setEnabled(false, userDefaults: defaults)
        assertFalse(LocalMeetingSummaryPreferences.isEnabled(userDefaults: defaults), "summary beta should read explicit off state")
    }

    runSuite("LocalMeetingSummaryPreferences keeps the storage key stable") {
        assertEqual(
            LocalMeetingSummaryPreferences.enabledKey,
            "localMeetingSummaryBetaEnabled",
            "storage key should not drift across updates"
        )
    }
}

private func makeLocalMeetingSummaryDefaults() -> (UserDefaults, String) {
    let suiteName = "LocalMeetingSummaryPreferencesTests-\(UUID().uuidString)"
    let defaults = UserDefaults(suiteName: suiteName)!
    defaults.removePersistentDomain(forName: suiteName)
    return (defaults, suiteName)
}
