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

    runSuite("A mic picked under Faster Bluetooth dictation carries over only while that toggle is on") {
        let suiteName = "MicrophoneChoicePreferencesTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let noEnvironment: [String: String] = [:]

        DictationPersistentInputPreferences.setPreferredDeviceUID("usb-mic", userDefaults: defaults)
        assertEqual(
            MicrophoneChoicePreferences.choice(userDefaults: defaults, environment: noEnvironment),
            .automatic,
            "a pick left behind after the toggle went off did nothing, so it must not become a forced mic"
        )

        DictationPersistentInputPreferences.setEnabled(true, userDefaults: defaults)
        assertEqual(
            MicrophoneChoicePreferences.choice(userDefaults: defaults, environment: noEnvironment),
            .device(uid: "usb-mic"),
            "a pick the toggle was using carries over"
        )
        assertNil(
            defaults.string(forKey: MicrophoneChoicePreferences.choiceKey),
            "with the recorder off nothing is settled yet"
        )

        PinnedMicrophoneCapturePreferences.setEnabled(true, userDefaults: defaults)
        assertEqual(
            MicrophoneChoicePreferences.choice(userDefaults: defaults, environment: noEnvironment),
            .device(uid: "usb-mic"),
            "the first read with the recorder on keeps the carried-over pick"
        )
        assertEqual(
            defaults.string(forKey: MicrophoneChoicePreferences.choiceKey),
            "device",
            "and settles it once"
        )
        DictationPersistentInputPreferences.setEnabled(false, userDefaults: defaults)
        assertEqual(
            MicrophoneChoicePreferences.choice(userDefaults: defaults, environment: noEnvironment),
            .device(uid: "usb-mic"),
            "a later change to the old toggle can't move a settled choice"
        )

        DictationPersistentInputPreferences.setPreferredDeviceUID(nil, userDefaults: defaults)
        assertEqual(
            MicrophoneChoicePreferences.choice(userDefaults: defaults, environment: noEnvironment),
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

    runSuite("Faster Bluetooth dictation stays off while the Mac mic recorder can handle dictation") {
        let suiteName = "MicrophoneChoicePreferencesTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let noEnvironment: [String: String] = [:]

        // Explicit, so the recorder's shipped default can't flip this test.
        PinnedMicrophoneCapturePreferences.setEnabled(false, userDefaults: defaults)
        DictationPersistentInputPreferences.setEnabled(true, userDefaults: defaults)
        assertTrue(
            DictationPersistentInputPreferences.isEnabled(userDefaults: defaults, environment: noEnvironment),
            "without the recorder the opt-in still works"
        )

        PinnedMicrophoneCapturePreferences.setEnabled(true, userDefaults: defaults)
        assertFalse(
            DictationPersistentInputPreferences.isEnabled(userDefaults: defaults, environment: noEnvironment),
            "the recorder reaches the Mac mic without switching the Mac-wide input, so this must hand the input back"
        )
        assertTrue(
            DictationPersistentInputPreferences.isStoredOn(userDefaults: defaults),
            "the saved toggle is kept for a Mac that turns the recorder off again"
        )

        MicrophoneProcessingPreferences.setMode(.appleVoiceProcessing, userDefaults: defaults)
        assertTrue(
            DictationPersistentInputPreferences.isEnabled(userDefaults: defaults, environment: noEnvironment),
            "voice-processing dictation never uses the recorder, so the Mac-wide switch still protects it from AirPods"
        )
        MicrophoneProcessingPreferences.setMode(.softwareAGC, userDefaults: defaults)

        PinnedMicrophoneCapturePreferences.setEnabled(false, userDefaults: defaults)
        assertTrue(
            DictationPersistentInputPreferences.isEnabled(userDefaults: defaults, environment: noEnvironment),
            "turning the recorder off brings the old opt-in back"
        )
        assertFalse(
            DictationPersistentInputPreferences.isEnabled(
                userDefaults: defaults,
                environment: [PinnedMicrophoneCapturePreferences.environmentKey: "1"]
            ),
            "the test-build environment switch counts as the recorder being on"
        )
    }

    runSuite("Settings shows the one Microphone picker only while the recorder is on") {
        let settings = readSourceFixture("Sources/UI/Settings/TranscriptedSettingsView.swift")
        assertTrue(
            settings.contains("if pinnedMicrophoneRecorderOn {\n            VStack(alignment: .leading, spacing: 0) {\n                generalMicrophoneChoiceEditor"),
            "the one picker shows while the recorder is on"
        )
        assertTrue(
            settings.contains("if meetingMicProcessingMode.usesAppleVoiceProcessing {\n                    Divider()\n                    generalFasterBluetoothDictationToggle"),
            "voice-processing users keep the toggle that still protects their dictation"
        )
        assertTrue(
            settings.contains("        } else {\n            generalFasterBluetoothDictationEditor\n        }"),
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
