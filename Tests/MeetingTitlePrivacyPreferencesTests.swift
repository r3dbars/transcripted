import Foundation

func testMeetingTitlePrivacyPreferences() {
    runSuite("MeetingTitlePrivacyPreferences defaults to showing real titles") {
        let (defaults, suiteName) = makeMeetingTitlePrivacyDefaults()
        defer { defaults.removePersistentDomain(forName: suiteName) }

        assertTrue(
            MeetingTitlePrivacyPreferences.showRealTitles(userDefaults: defaults),
            "real titles should show by default (spec Q5: real title normally)"
        )
    }

    runSuite("MeetingTitlePrivacyPreferences persists the generic-label opt-in") {
        let (defaults, suiteName) = makeMeetingTitlePrivacyDefaults()
        defer { defaults.removePersistentDomain(forName: suiteName) }

        MeetingTitlePrivacyPreferences.setShowRealTitles(false, userDefaults: defaults)
        assertFalse(
            MeetingTitlePrivacyPreferences.showRealTitles(userDefaults: defaults),
            "opting into the generic label should round-trip and stay off"
        )

        MeetingTitlePrivacyPreferences.setShowRealTitles(true, userDefaults: defaults)
        assertTrue(
            MeetingTitlePrivacyPreferences.showRealTitles(userDefaults: defaults),
            "re-enabling real titles should round-trip back on"
        )
    }

    runSuite("MeetingTitlePrivacyPreferences uses a stable storage key and label") {
        assertEqual(
            MeetingTitlePrivacyPreferences.showRealTitlesKey,
            "meeting-prompt-show-real-titles",
            "storage key must stay stable across releases"
        )
        assertEqual(
            MeetingTitlePrivacyPreferences.genericTitle,
            "Meeting",
            "the privacy fallback label must stay generic"
        )
    }
}

private func makeMeetingTitlePrivacyDefaults() -> (UserDefaults, String) {
    let suiteName = "MeetingTitlePrivacyPreferencesTests-\(UUID().uuidString)"
    let defaults = UserDefaults(suiteName: suiteName)!
    defaults.removePersistentDomain(forName: suiteName)
    return (defaults, suiteName)
}
