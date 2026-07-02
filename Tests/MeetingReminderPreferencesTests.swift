import Foundation

func testMeetingReminderPreferences() {
    runSuite("MeetingReminderPreferences defaults to enabled") {
        let suiteName = "MeetingReminderPreferencesTests.default.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }

        assertTrue(
            MeetingReminderPreferences.isEnabled(userDefaults: defaults),
            "meeting reminders should default on until the user first toggles them"
        )
    }

    runSuite("MeetingReminderPreferences persists an explicit opt-out") {
        let suiteName = "MeetingReminderPreferencesTests.opt-out.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }

        MeetingReminderPreferences.setEnabled(false, userDefaults: defaults)
        assertFalse(
            MeetingReminderPreferences.isEnabled(userDefaults: defaults),
            "turning meeting reminders off should persist"
        )
        assertNotNil(
            defaults.object(forKey: MeetingReminderPreferences.enabledKey),
            "the opt-out should be stored under the stable preference key"
        )

        MeetingReminderPreferences.setEnabled(true, userDefaults: defaults)
        assertTrue(
            MeetingReminderPreferences.isEnabled(userDefaults: defaults),
            "re-enabling meeting reminders should persist"
        )
    }
}
