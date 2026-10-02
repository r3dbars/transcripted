import Foundation

func testMicrophoneSettingsPolicy() {
    runSuite("The one Microphone picker shows only while the Mac mic recorder is on") {
        for voiceProcessing in [false, true] {
            let on = MicrophoneSettingsPolicy.rows(recorderOn: true, usesAppleVoiceProcessing: voiceProcessing)
            assertTrue(on.showsMicrophoneChoicePicker, "recorder on shows the one picker")
            assertFalse(on.showsFasterBluetoothMicPicker, "recorder on hides the old Bluetooth mic picker")
            assertFalse(on.showsMeetingMacInputToggle, "recorder on folds meetings' macOS-input toggle into the picker")

            let off = MicrophoneSettingsPolicy.rows(recorderOn: false, usesAppleVoiceProcessing: voiceProcessing)
            assertFalse(off.showsMicrophoneChoicePicker, "recorder off hides the one picker")
            assertTrue(off.showsFasterBluetoothDictationToggle, "recorder off keeps Faster Bluetooth dictation")
            assertTrue(off.showsFasterBluetoothMicPicker, "recorder off keeps its mic picker")
            assertTrue(off.showsMeetingMacInputToggle, "recorder off keeps meetings' macOS-input toggle")
        }
    }

    runSuite("Voice-processing users keep the Faster Bluetooth dictation toggle next to the picker") {
        assertTrue(
            MicrophoneSettingsPolicy.rows(recorderOn: true, usesAppleVoiceProcessing: true).showsFasterBluetoothDictationToggle,
            "Apple voice processing keeps dictation off the recorder, so the toggle still protects AirPods"
        )
        assertFalse(
            MicrophoneSettingsPolicy.rows(recorderOn: true, usesAppleVoiceProcessing: false).showsFasterBluetoothDictationToggle,
            "without voice processing the picker replaces the toggle"
        )
    }

    runSuite("The Microphone picker always offers Same as macOS Sound settings, last") {
        let cases: [([(uid: String?, name: String)], MicrophoneChoice)] = [
            ([], .automatic),
            ([(uid: "airpods", name: "AirPods")], .macOSInput),
            ([(uid: "usb", name: "USB Mic")], .device(uid: "usb")),
        ]
        for (candidates, selection) in cases {
            let options = MicrophoneSettingsPolicy.pickerOptions(candidates: candidates, selection: selection)
            assertEqual(options.first, .automatic, "Automatic comes first")
            assertEqual(options.last, .macOSInput, "the AirPods mic can still be recorded on purpose")
            assertEqual(options.last?.choice, .macOSInput, "the last entry selects the macOS input")
        }
    }

    runSuite("The Microphone picker lists connected mics with a UID, in order") {
        let options = MicrophoneSettingsPolicy.pickerOptions(
            candidates: [
                (uid: "builtin", name: "MacBook Pro Microphone"),
                (uid: nil, name: "No UID"),
                (uid: "usb", name: "USB Mic"),
            ],
            selection: .device(uid: "usb")
        )
        assertEqual(
            options,
            [
                .automatic,
                .device(uid: "builtin", name: "MacBook Pro Microphone"),
                .device(uid: "usb", name: "USB Mic"),
                .divider,
                .macOSInput,
            ],
            "a mic without a UID can't be pinned, and a connected pick isn't listed twice"
        )
    }

    runSuite("An unplugged saved mic stays in the picker instead of a blank menu") {
        let options = MicrophoneSettingsPolicy.pickerOptions(
            candidates: [(uid: "builtin", name: "MacBook Pro Microphone")],
            selection: .device(uid: "gone")
        )
        assertEqual(
            options,
            [
                .automatic,
                .device(uid: "builtin", name: "MacBook Pro Microphone"),
                .savedDeviceNotConnected(uid: "gone"),
                .divider,
                .macOSInput,
            ],
            "the saved pick shows as not connected, before the divider"
        )
        assertEqual(options[2].choice, .device(uid: "gone"), "it still selects the saved mic")
        assertEqual(MicrophoneChoicePickerOption.divider.choice, nil, "the divider selects nothing")
    }
}
