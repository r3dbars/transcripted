import Foundation

func testMenuBarVisibilityPreferences() {
    runSuite("MenuBarVisibilityPreferences defaults optional rows to visible") {
        let suiteName = "MenuBarVisibilityPreferencesTests.default.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }

        for item in MenuBarOptionalItem.allCases {
            assertTrue(
                MenuBarVisibilityPreferences.isVisible(item, userDefaults: defaults),
                "\(item.title) should default visible"
            )
        }
    }

    runSuite("MenuBarVisibilityPreferences stores each optional row independently") {
        let suiteName = "MenuBarVisibilityPreferencesTests.persist.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }

        MenuBarVisibilityPreferences.setVisible(.recentMeetings, false, userDefaults: defaults)
        MenuBarVisibilityPreferences.setVisible(.connectAgent, false, userDefaults: defaults)
        MenuBarVisibilityPreferences.setVisible(.submitFeedback, true, userDefaults: defaults)
        MenuBarVisibilityPreferences.setVisible(.updates, false, userDefaults: defaults)

        assertFalse(
            MenuBarVisibilityPreferences.isVisible(.recentMeetings, userDefaults: defaults),
            "Recent Meetings should respect explicit hidden state"
        )
        assertFalse(
            MenuBarVisibilityPreferences.isVisible(.connectAgent, userDefaults: defaults),
            "Connect Agent should respect explicit hidden state"
        )
        assertTrue(
            MenuBarVisibilityPreferences.isVisible(.submitFeedback, userDefaults: defaults),
            "Submit Feedback should respect explicit visible state"
        )
        assertFalse(
            MenuBarVisibilityPreferences.isVisible(.updates, userDefaults: defaults),
            "Updates should respect explicit hidden state"
        )

        let snapshot = MenuBarVisibilityPreferences.snapshot(userDefaults: defaults)
        assertEqual(snapshot[.recentMeetings], false, "snapshot should include Recent Meetings")
        assertEqual(snapshot[.connectAgent], false, "snapshot should include Connect Agent")
        assertEqual(snapshot[.submitFeedback], true, "snapshot should include Submit Feedback")
        assertEqual(snapshot[.updates], false, "snapshot should include Updates")
    }
}
