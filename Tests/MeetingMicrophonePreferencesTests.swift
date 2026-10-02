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
    }

    runSuite("Meeting start picks the mic through the recorder-aware check") {
        let suiteName = "MeetingMicrophonePreferencesTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }
        MeetingMicrophonePreferences.setUsesSystemInput(true, userDefaults: defaults)

        func plan(recorderOn: Bool, choice: MicrophoneChoice) -> MeetingMicStartPlan {
            MeetingMicStartPlan.make(
                processingMode: .softwareAGC,
                boostRequestedForThisMeeting: false,
                pinnedRecorderOn: recorderOn,
                microphoneChoice: choice,
                userDefaults: defaults
            )
        }

        assertTrue(
            plan(recorderOn: false, choice: .automatic).recordsMacOSInput,
            "without the recorder, the saved system-mic setting still applies at start"
        )
        assertFalse(
            plan(recorderOn: true, choice: .automatic).recordsMacOSInput,
            "with the recorder on, the raw setting must not put meetings back on the AirPods mic"
        )
        assertTrue(
            plan(recorderOn: true, choice: .macOSInput).recordsMacOSInput,
            "with the recorder on, \"Same as macOS Sound settings\" records the macOS input"
        )
        assertEqual(
            plan(recorderOn: true, choice: .device(uid: "usb-mic")).preferredInputDeviceUID,
            "usb-mic",
            "a mic picked in Settings applies to meetings while the recorder shows that picker"
        )
        assertNil(
            plan(recorderOn: false, choice: .device(uid: "usb-mic")).preferredInputDeviceUID,
            "a mic left picked after the recorder went off must not steer meetings"
        )
        assertTrue(plan(recorderOn: true, choice: .automatic).usesPinnedMicrophoneCapture, "the recorder setting reaches capture")
        assertFalse(plan(recorderOn: false, choice: .automatic).usesPinnedMicrophoneCapture, "the recorder stays off when its setting is off")
    }
}
