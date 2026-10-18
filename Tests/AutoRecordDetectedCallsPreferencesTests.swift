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

        assertFalse(
            AutoRecordDetectedCallsPreferences.isStoredOn(userDefaults: defaults),
            "turning auto-detect off must clear auto-record so it cannot quietly come back"
        )
        assertFalse(
            AutoRecordDetectedCallsPreferences.isEnabled(userDefaults: defaults),
            "auto-record cannot fire while auto-detect is off"
        )

        AutoCallDetectionPreferences.setEnabled(true, userDefaults: defaults)
        assertFalse(
            AutoRecordDetectedCallsPreferences.isEnabled(userDefaults: defaults),
            "turning auto-detect back on must not silently re-enable auto-record"
        )
    }

    runSuite("AutoRecordDetectedCallsConsentPolicy asks once when first enabled") {
        assertTrue(
            AutoRecordDetectedCallsConsentPolicy.shouldConfirm(acknowledged: false),
            "the first enable needs a confirmation"
        )
        assertFalse(
            AutoRecordDetectedCallsConsentPolicy.shouldConfirm(acknowledged: true),
            "later enables must not ask again"
        )
    }

    runSuite("AutoRecordDetectedCallsPreferences remembers the consent acknowledgement") {
        let (defaults, suiteName) = makeAutoRecordDetectedCallsDefaults()
        defer { defaults.removePersistentDomain(forName: suiteName) }

        assertFalse(
            AutoRecordDetectedCallsPreferences.hasAcknowledgedConsent(userDefaults: defaults),
            "consent starts unacknowledged"
        )
        AutoRecordDetectedCallsPreferences.acknowledgeConsent(userDefaults: defaults)
        assertTrue(
            AutoRecordDetectedCallsPreferences.hasAcknowledgedConsent(userDefaults: defaults),
            "an acknowledgement should round-trip"
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
