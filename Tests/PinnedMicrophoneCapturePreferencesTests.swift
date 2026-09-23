import Foundation

func testPinnedMicrophoneCapturePreferences() {
    runSuite("PinnedMicrophoneCapturePreferences turns on per Mac") {
        let (defaults, suiteName) = makePinnedMicrophoneCaptureDefaults()
        defer { defaults.removePersistentDomain(forName: suiteName) }

        PinnedMicrophoneCapturePreferences.setEnabled(true, userDefaults: defaults)
        assertEqual(
            PinnedMicrophoneCapturePreferences.isEnabled(userDefaults: defaults, environment: [:]),
            true,
            "The defaults switch turns it on"
        )
    }

    runSuite("PinnedMicrophoneCapturePreferences follows the shipped default until a Mac chooses") {
        let (defaults, suiteName) = makePinnedMicrophoneCaptureDefaults()
        defer { defaults.removePersistentDomain(forName: suiteName) }

        assertEqual(
            PinnedMicrophoneCapturePreferences.isEnabled(userDefaults: defaults, environment: [:]),
            PinnedMicrophoneCapturePreferences.shipsOnByDefault,
            "An untouched Mac gets whatever the release ships"
        )
        PinnedMicrophoneCapturePreferences.setEnabled(false, userDefaults: defaults)
        assertEqual(
            PinnedMicrophoneCapturePreferences.isEnabled(userDefaults: defaults, environment: [:]),
            false,
            "An explicit off stays off even after the default flips on"
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
