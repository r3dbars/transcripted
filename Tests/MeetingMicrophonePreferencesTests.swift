import Foundation

func testMeetingMicrophonePreferences() {
    runSuite("Meeting microphone selection preserves existing defaults and explicit choice") {
        let suiteName = "MeetingMicrophonePreferencesTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }

        assertFalse(MeetingMicrophonePreferences.usesSystemInput(userDefaults: defaults), "existing installs must retain automatic Bluetooth isolation")
        MeetingMicrophonePreferences.setUsesSystemInput(true, userDefaults: defaults)
        assertTrue(MeetingMicrophonePreferences.usesSystemInput(userDefaults: UserDefaults(suiteName: suiteName)!), "the explicit system-mic choice must survive reopening settings")
        MeetingMicrophonePreferences.setUsesSystemInput(false, userDefaults: defaults)
        assertFalse(MeetingMicrophonePreferences.usesSystemInput(userDefaults: defaults), "the user can return to automatic selection")
    }

    runSuite("The pinned Mac-mic recorder keeps meetings off a Bluetooth headset mic") {
        let suiteName = "MeetingMicrophonePreferencesTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }

        MeetingMicrophonePreferences.setUsesSystemInput(true, userDefaults: defaults)
        assertTrue(
            MeetingMicrophonePreferences.recordsMacOSInput(pinnedRecorderOn: false, userDefaults: defaults),
            "without the recorder, the setting still records the macOS input as-is"
        )
        assertFalse(
            MeetingMicrophonePreferences.recordsMacOSInput(pinnedRecorderOn: true, userDefaults: defaults),
            "with the recorder on, AirPods as the macOS input must not be recorded and flipped into call mode"
        )
        MeetingMicrophonePreferences.setUsesSystemInput(false, userDefaults: defaults)
        assertFalse(
            MeetingMicrophonePreferences.recordsMacOSInput(pinnedRecorderOn: false, userDefaults: defaults),
            "automatic selection stays automatic"
        )

        let bridge = readSourceFixture("Sources/Meeting/MeetingCaptureBridge.swift")
        assertTrue(
            bridge.contains("audio.meetingInputDeviceSelectionMode = MeetingMicrophonePreferences.recordsMacOSInput("),
            "meeting start must choose the mic mode through the recorder-aware check"
        )
        assertFalse(
            bridge.contains("audio.meetingInputDeviceSelectionMode = MeetingMicrophonePreferences.usesSystemInput()"),
            "reading the raw setting put meetings back on the AirPods mic"
        )
    }
}
