import Foundation

func testPinnedMicrophoneCapturePreferences() {
    runSuite("PinnedMicrophoneCapturePreferences stays off until turned on") {
        let (defaults, suiteName) = makePinnedMicrophoneCaptureDefaults()
        defer { defaults.removePersistentDomain(forName: suiteName) }

        assertEqual(
            PinnedMicrophoneCapturePreferences.isEnabled(userDefaults: defaults, environment: [:]),
            false,
            "The pinned recorder ships dark until it passes hardware testing"
        )
        PinnedMicrophoneCapturePreferences.setEnabled(true, userDefaults: defaults)
        assertEqual(
            PinnedMicrophoneCapturePreferences.isEnabled(userDefaults: defaults, environment: [:]),
            true,
            "The defaults switch turns it on"
        )
    }

    runSuite("PinnedMicrophoneCapturePreferences environment override wins both ways") {
        let (defaults, suiteName) = makePinnedMicrophoneCaptureDefaults()
        defer { defaults.removePersistentDomain(forName: suiteName) }

        assertEqual(
            PinnedMicrophoneCapturePreferences.isEnabled(
                userDefaults: defaults,
                environment: [PinnedMicrophoneCapturePreferences.environmentKey: "1"]
            ),
            true,
            "A test run can force it on"
        )
        PinnedMicrophoneCapturePreferences.setEnabled(true, userDefaults: defaults)
        assertEqual(
            PinnedMicrophoneCapturePreferences.isEnabled(
                userDefaults: defaults,
                environment: [PinnedMicrophoneCapturePreferences.environmentKey: "0"]
            ),
            false,
            "A test run can force it off"
        )
    }
}

private func makePinnedMicrophoneCaptureDefaults() -> (UserDefaults, String) {
    let suiteName = "PinnedMicrophoneCapturePreferencesTests-\(UUID().uuidString)"
    let defaults = UserDefaults(suiteName: suiteName)!
    defaults.removePersistentDomain(forName: suiteName)
    return (defaults, suiteName)
}
