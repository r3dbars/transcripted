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

        MenuBarVisibilityPreferences.setVisible(.startDictation, false, userDefaults: defaults)
        MenuBarVisibilityPreferences.setVisible(.startMeeting, false, userDefaults: defaults)
        MenuBarVisibilityPreferences.setVisible(.pasteLastDictation, true, userDefaults: defaults)
        MenuBarVisibilityPreferences.setVisible(.recentMeetings, false, userDefaults: defaults)

        assertFalse(
            MenuBarVisibilityPreferences.isVisible(.startDictation, userDefaults: defaults),
            "Start Dictation should respect explicit hidden state"
        )
        assertFalse(
            MenuBarVisibilityPreferences.isVisible(.startMeeting, userDefaults: defaults),
            "Start Meeting should respect explicit hidden state"
        )
        assertTrue(
            MenuBarVisibilityPreferences.isVisible(.pasteLastDictation, userDefaults: defaults),
            "Paste Last Dictation should respect explicit visible state"
        )
        assertFalse(
            MenuBarVisibilityPreferences.isVisible(.recentMeetings, userDefaults: defaults),
            "Recent Meetings should respect explicit hidden state"
        )

        let snapshot = MenuBarVisibilityPreferences.snapshot(userDefaults: defaults)
        assertEqual(snapshot[.startDictation], false, "snapshot should include Start Dictation")
        assertEqual(snapshot[.startMeeting], false, "snapshot should include Start Meeting")
        assertEqual(snapshot[.pasteLastDictation], true, "snapshot should include Paste Last Dictation")
        assertEqual(snapshot[.recentMeetings], false, "snapshot should include Recent Meetings")
    }
}
