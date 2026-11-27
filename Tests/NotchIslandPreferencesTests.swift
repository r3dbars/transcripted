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

    runSuite("NotchIslandPreferences requires opt-in for mute and always allows explicit unmute") {
        let (defaults, suiteName) = makeNotchIslandPreferencesDefaults()
        defer { defaults.removePersistentDomain(forName: suiteName) }
        assertFalse(NotchIslandPreferences.allowsMeetingMicChange(toMuted: true, userDefaults: defaults))
        assertFalse(NotchIslandPreferences.meetingMicMuteControlEnabled(userDefaults: defaults))
        defaults.set(true, forKey: NotchIslandPreferences.meetingMicMuteControlKey)
        let reopened = UserDefaults(suiteName: suiteName)!
        assertTrue(NotchIslandPreferences.allowsMeetingMicChange(toMuted: true, userDefaults: reopened))
        defaults.set(false, forKey: NotchIslandPreferences.meetingMicMuteControlKey)
        assertFalse(NotchIslandPreferences.allowsMeetingMicChange(toMuted: true, userDefaults: reopened))
        assertTrue(NotchIslandPreferences.allowsMeetingMicChange(toMuted: false, userDefaults: reopened))
    }

    runSuite("Live meeting words stay off until turned on") {
        let (defaults, suiteName) = makeNotchIslandPreferencesDefaults()
        defer { defaults.removePersistentDomain(forName: suiteName) }

        assertNil(defaults.object(forKey: NotchIslandPreferences.showsLiveTranscriptKey), "a fresh install has no stored value")
        assertFalse(
            NotchIslandPreferences.showsLiveTranscript(userDefaults: defaults),
            "unset reads off: meetings don't run live transcription unless asked"
        )
        NotchIslandPreferences.setShowsLiveTranscript(true, userDefaults: defaults)
        let reopened = UserDefaults(suiteName: suiteName)!
        assertTrue(NotchIslandPreferences.showsLiveTranscript(userDefaults: reopened), "turning it on persists")
        NotchIslandPreferences.setShowsLiveTranscript(false, userDefaults: reopened)
        assertFalse(NotchIslandPreferences.showsLiveTranscript(userDefaults: defaults), "and turning it off sticks")
    }
}

private func makeNotchIslandPreferencesDefaults() -> (UserDefaults, String) {
    let suiteName = "NotchIslandPreferencesTests-\(UUID().uuidString)"
    let defaults = UserDefaults(suiteName: suiteName)!
    defaults.removePersistentDomain(forName: suiteName)
    return (defaults, suiteName)
}
