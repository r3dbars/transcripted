import Foundation

func testMeetingLiveTranscriptPreferences() {
    runSuite("MeetingLiveTranscriptPreferences — drawer defaults open and remembers the choice") {
        let (defaults, suiteName) = makeMeetingLiveTranscriptDefaults()
        assertTrue(MeetingLiveTranscriptPreferences.isDrawerOpenPreferred(userDefaults: defaults))
        MeetingLiveTranscriptPreferences.setDrawerOpenPreferred(false, userDefaults: defaults)
        assertFalse(MeetingLiveTranscriptPreferences.isDrawerOpenPreferred(userDefaults: defaults))
        MeetingLiveTranscriptPreferences.setDrawerOpenPreferred(true, userDefaults: defaults)
        assertTrue(MeetingLiveTranscriptPreferences.isDrawerOpenPreferred(userDefaults: defaults))
        defaults.removePersistentDomain(forName: suiteName)
    }

    runSuite("MeetingLiveTranscriptPreferences — drawer height defaults, clamps, and persists") {
        let (defaults, suiteName) = makeMeetingLiveTranscriptDefaults()
        assertEqual(MeetingLiveTranscriptPreferences.preferredDrawerHeight(userDefaults: defaults), MeetingLiveTranscriptPreferences.defaultDrawerHeight)
        MeetingLiveTranscriptPreferences.setPreferredDrawerHeight(320, userDefaults: defaults)
        assertEqual(MeetingLiveTranscriptPreferences.preferredDrawerHeight(userDefaults: defaults), 320)
        MeetingLiveTranscriptPreferences.setPreferredDrawerHeight(40, userDefaults: defaults)
        assertEqual(MeetingLiveTranscriptPreferences.preferredDrawerHeight(userDefaults: defaults), MeetingLiveTranscriptPreferences.minimumDrawerHeight)
        MeetingLiveTranscriptPreferences.setPreferredDrawerHeight(2000, userDefaults: defaults)
        assertEqual(MeetingLiveTranscriptPreferences.preferredDrawerHeight(userDefaults: defaults), MeetingLiveTranscriptPreferences.maximumDrawerHeight)
        defaults.removePersistentDomain(forName: suiteName)
    }

    runSuite("MeetingLiveTranscriptPreferences — clamp helper bounds") {
        assertEqual(MeetingLiveTranscriptPreferences.clampedDrawerHeight(0), MeetingLiveTranscriptPreferences.minimumDrawerHeight)
        assertEqual(MeetingLiveTranscriptPreferences.clampedDrawerHeight(300), 300)
        assertEqual(MeetingLiveTranscriptPreferences.clampedDrawerHeight(.greatestFiniteMagnitude), MeetingLiveTranscriptPreferences.maximumDrawerHeight)
    }
}

private func makeMeetingLiveTranscriptDefaults() -> (UserDefaults, String) {
    let suiteName = "MeetingLiveTranscriptPreferencesTests-\(UUID().uuidString)"
    let defaults = UserDefaults(suiteName: suiteName)!
    defaults.removePersistentDomain(forName: suiteName)
    return (defaults, suiteName)
}
