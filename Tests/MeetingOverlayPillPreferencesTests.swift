import Foundation

func testMeetingOverlayPillPreferences() {
    runSuite("MeetingOverlayPillPreferences — auto-rest is the default, pin persists") {
        let (defaults, suiteName) = makeMeetingOverlayPillDefaults()
        defer { UserDefaults().removePersistentDomain(forName: suiteName) }

        assertFalse(
            MeetingOverlayPillPreferences.keepControlsVisible(userDefaults: defaults),
            "the pill should rest by default; pinning is the explicit opt-out"
        )

        MeetingOverlayPillPreferences.setKeepControlsVisible(true, userDefaults: defaults)
        assertTrue(
            MeetingOverlayPillPreferences.keepControlsVisible(userDefaults: defaults),
            "an explicit pin should stick across meetings"
        )

        MeetingOverlayPillPreferences.setKeepControlsVisible(false, userDefaults: defaults)
        assertFalse(MeetingOverlayPillPreferences.keepControlsVisible(userDefaults: defaults))
    }
}

private func makeMeetingOverlayPillDefaults() -> (UserDefaults, String) {
    let suiteName = "MeetingOverlayPillPreferencesTests-\(UUID().uuidString)"
    let defaults = UserDefaults(suiteName: suiteName)!
    defaults.removePersistentDomain(forName: suiteName)
    return (defaults, suiteName)
}
