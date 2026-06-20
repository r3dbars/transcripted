import Foundation

func testCalendarPreArmPreferences() {
    runSuite("CalendarPreArmPreferences defaults to enabled") {
        let (defaults, suiteName) = makeCalendarPreArmDefaults()
        defer { defaults.removePersistentDomain(forName: suiteName) }

        assertTrue(
            CalendarPreArmPreferences.isEnabled(userDefaults: defaults),
            "calendar pre-arm should be on by default (gentle tier, on after calendar access)"
        )
    }

    runSuite("CalendarPreArmPreferences persists disabled and re-enabled states") {
        let (defaults, suiteName) = makeCalendarPreArmDefaults()
        defer { defaults.removePersistentDomain(forName: suiteName) }

        CalendarPreArmPreferences.setEnabled(false, userDefaults: defaults)
        assertFalse(
            CalendarPreArmPreferences.isEnabled(userDefaults: defaults),
            "an explicit opt-out should round-trip and stay off (the kill switch)"
        )

        CalendarPreArmPreferences.setEnabled(true, userDefaults: defaults)
        assertTrue(
            CalendarPreArmPreferences.isEnabled(userDefaults: defaults),
            "an explicit opt-in should round-trip back on"
        )
    }

    runSuite("CalendarPreArmPreferences uses a stable storage key") {
        assertEqual(
            CalendarPreArmPreferences.enabledKey,
            "calendar-prearm-enabled",
            "storage key must stay stable across releases"
        )
    }
}

private func makeCalendarPreArmDefaults() -> (UserDefaults, String) {
    let suiteName = "CalendarPreArmPreferencesTests-\(UUID().uuidString)"
    let defaults = UserDefaults(suiteName: suiteName)!
    defaults.removePersistentDomain(forName: suiteName)
    return (defaults, suiteName)
}
