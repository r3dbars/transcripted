import Foundation

func testMicrophoneChoicePreferences() {
    runSuite("The one Microphone choice defaults to Automatic and persists") {
        let suiteName = "MicrophoneChoicePreferencesTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }

        assertEqual(MicrophoneChoicePreferences.choice(userDefaults: defaults), .automatic, "a fresh install starts on Automatic")

        MicrophoneChoicePreferences.setChoice(.device(uid: "mv7"), userDefaults: defaults)
        assertEqual(MicrophoneChoicePreferences.choice(userDefaults: defaults), .device(uid: "mv7"), "a picked mic survives reopening settings")
        assertEqual(
            DictationPersistentInputPreferences.preferredDeviceUID(userDefaults: defaults),
            "mv7",
            "the pick is saved where the older dictation mic picker keeps it"
        )

        MicrophoneChoicePreferences.setChoice(.macOSInput, userDefaults: defaults)
        assertEqual(MicrophoneChoicePreferences.choice(userDefaults: defaults), .macOSInput, "the macOS-input choice persists")

        MicrophoneChoicePreferences.setChoice(.automatic, userDefaults: defaults)
        assertEqual(MicrophoneChoicePreferences.choice(userDefaults: defaults), .automatic, "the user can go back to Automatic")
        assertEqual(
            DictationPersistentInputPreferences.preferredDeviceUID(userDefaults: defaults),
            "mv7",
            "going back to Automatic leaves the older picker's saved mic alone"
        )
    }

    runSuite("A mic saved under Faster Bluetooth dictation carries over until the user picks again") {
        let suiteName = "MicrophoneChoicePreferencesTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }

        DictationPersistentInputPreferences.setPreferredDeviceUID("usb-mic", userDefaults: defaults)
        assertEqual(MicrophoneChoicePreferences.choice(userDefaults: defaults), .device(uid: "usb-mic"), "an existing pick becomes the choice")

        MicrophoneChoicePreferences.setChoice(.device(uid: "usb-mic"), userDefaults: defaults)
        DictationPersistentInputPreferences.setPreferredDeviceUID(nil, userDefaults: defaults)
        assertEqual(
            MicrophoneChoicePreferences.choice(userDefaults: defaults),
            .automatic,
            "a pick cleared from the older picker falls back to Automatic instead of an empty mic"
        )
    }

    runSuite("Analytics carries only the kind of choice, never the mic") {
        assertEqual(MicrophoneChoice.automatic.analyticsValue, "automatic", "bounded value")
        assertEqual(MicrophoneChoice.device(uid: "BuiltInMicrophoneDevice").analyticsValue, "device", "the device UID stays on the Mac")
        assertEqual(MicrophoneChoice.macOSInput.analyticsValue, "macos_input", "bounded value")
        assertEqual(MicrophoneChoice.device(uid: "mv7").deviceUID, "mv7", "the UID is still there for recording")
        assertEqual(MicrophoneChoice.automatic.deviceUID, nil, "no UID for Automatic")
    }

    runSuite("Faster Bluetooth dictation stays off while the Mac mic recorder is on") {
        let suiteName = "MicrophoneChoicePreferencesTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }

        DictationPersistentInputPreferences.setEnabled(true, userDefaults: defaults)
        assertTrue(DictationPersistentInputPreferences.isEnabled(userDefaults: defaults), "without the recorder the opt-in still works")

        PinnedMicrophoneCapturePreferences.setEnabled(true, userDefaults: defaults)
        assertFalse(
            DictationPersistentInputPreferences.isEnabled(userDefaults: defaults),
            "the recorder reaches the Mac mic without switching the Mac-wide input, so this must hand the input back"
        )

        PinnedMicrophoneCapturePreferences.setEnabled(false, userDefaults: defaults)
        assertTrue(DictationPersistentInputPreferences.isEnabled(userDefaults: defaults), "turning the recorder off brings the old opt-in back")
    }

    runSuite("Settings shows the one Microphone picker only while the recorder is on") {
        let settings = readSourceFixture("Sources/UI/Settings/TranscriptedSettingsView.swift")
        assertTrue(
            settings.contains("if pinnedMicrophoneRecorderOn {\n            generalMicrophoneChoiceEditor\n        } else {\n            generalFasterBluetoothDictationEditor\n        }"),
            "the old Bluetooth dictation rows stay while the recorder is off"
        )
        assertTrue(
            settings.contains("if !pinnedMicrophoneRecorderOn {\n                        MeetingMicrophoneSettingRow("),
            "the meetings-only macOS-input toggle is folded into the one picker while the recorder is on"
        )
        assertTrue(
            settings.contains("Text(\"Same as macOS Sound settings\").tag(MicrophoneChoice.macOSInput)"),
            "the picker keeps a way to record the AirPods mic on purpose"
        )
    }
}
