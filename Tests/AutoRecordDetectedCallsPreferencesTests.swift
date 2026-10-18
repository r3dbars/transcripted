import Foundation

func testAutoRecordDetectedCallsPreferences() {
    runSuite("AutoRecordDetectedCallsPreferences defaults to disabled") {
        let (defaults, suiteName) = makeAutoRecordDetectedCallsDefaults()
        defer { defaults.removePersistentDomain(forName: suiteName) }

        assertFalse(
            AutoRecordDetectedCallsPreferences.isEnabled(userDefaults: defaults),
            "auto-record must stay off until someone turns it on"
        )
        assertFalse(
            AutoRecordDetectedCallsPreferences.isStoredOn(userDefaults: defaults),
            "a missing key is stored-off, not an implicit opt-in"
        )
    }

    runSuite("AutoRecordDetectedCallsPreferences persists an explicit opt-in") {
        let (defaults, suiteName) = makeAutoRecordDetectedCallsDefaults()
        defer { defaults.removePersistentDomain(forName: suiteName) }

        AutoRecordDetectedCallsPreferences.setEnabled(true, userDefaults: defaults)
        assertTrue(
            AutoRecordDetectedCallsPreferences.isStoredOn(userDefaults: defaults),
            "an explicit opt-in should round-trip"
        )
        assertTrue(
            AutoRecordDetectedCallsPreferences.isEnabled(userDefaults: defaults),
            "parent auto-detect is on by default, so a stored opt-in is enabled"
        )

        AutoRecordDetectedCallsPreferences.setEnabled(false, userDefaults: defaults)
        assertFalse(
            AutoRecordDetectedCallsPreferences.isEnabled(userDefaults: defaults),
            "an explicit opt-out should round-trip back off"
        )
    }

    runSuite("AutoRecordDetectedCallsPreferences stays off when auto-detect is off") {
        let (defaults, suiteName) = makeAutoRecordDetectedCallsDefaults()
        defer { defaults.removePersistentDomain(forName: suiteName) }

        AutoRecordDetectedCallsPreferences.setEnabled(true, userDefaults: defaults)
        AutoCallDetectionPreferences.setEnabled(false, userDefaults: defaults)

        assertTrue(
            AutoRecordDetectedCallsPreferences.isStoredOn(userDefaults: defaults),
            "turning auto-detect off must not wipe the stored auto-record choice"
        )
        assertFalse(
            AutoRecordDetectedCallsPreferences.isEnabled(userDefaults: defaults),
            "auto-record cannot fire while auto-detect is off"
        )
    }

    runSuite("AutoRecordDetectedCallsPreferences uses a stable storage key") {
        assertEqual(
            AutoRecordDetectedCallsPreferences.enabledKey,
            "auto-record-detected-calls-enabled",
            "storage key must stay stable across releases"
        )
    }
}

private func makeAutoRecordDetectedCallsDefaults() -> (UserDefaults, String) {
    let suiteName = "AutoRecordDetectedCallsPreferencesTests-\(UUID().uuidString)"
    let defaults = UserDefaults(suiteName: suiteName)!
    defaults.removePersistentDomain(forName: suiteName)
    return (defaults, suiteName)
}
