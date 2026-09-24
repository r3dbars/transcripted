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
            MeetingMicrophonePreferences.recordsMacOSInput(pinnedRecorderOn: false, microphoneChoice: .automatic, userDefaults: defaults),
            "without the recorder, the setting still records the macOS input as-is"
        )
        for choice in [MicrophoneChoice.automatic, .device(uid: "usb-mic")] {
            assertFalse(
                MeetingMicrophonePreferences.recordsMacOSInput(pinnedRecorderOn: true, microphoneChoice: choice, userDefaults: defaults),
                "with the recorder on, the old setting must not put AirPods as the macOS input back into call mode"
            )
        }
        MeetingMicrophonePreferences.setUsesSystemInput(false, userDefaults: defaults)
        assertFalse(
            MeetingMicrophonePreferences.recordsMacOSInput(pinnedRecorderOn: false, microphoneChoice: .macOSInput, userDefaults: defaults),
            "without the recorder, the one Microphone choice is hidden and ignored"
        )
        assertTrue(
            MeetingMicrophonePreferences.recordsMacOSInput(pinnedRecorderOn: true, microphoneChoice: .macOSInput, userDefaults: defaults),
            "with the recorder on, only \"Same as macOS Sound settings\" records the macOS input as-is"
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
        assertTrue(
            bridge.contains("audio.meetingPreferredInputDeviceUID = pinnedRecorderOn ? microphoneChoice.deviceUID : nil"),
            "a mic picked in Settings applies to meetings only while the recorder shows that picker"
        )
    }
}
