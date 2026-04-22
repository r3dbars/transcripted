import Foundation

func testDictationInputDeviceSelectionPolicy() {
    runSuite("DictationInputDeviceSelectionPolicy chooses MacBook mic for AirPods input/output") {
        let airPodsInput = device(1, "Justin's AirPods Pro", .bluetooth)
        let airPodsOutput = device(2, "Justin's AirPods Pro", .bluetooth, inputChannels: 0)
        let macBookMic = device(3, "MacBook Pro Microphone", .builtIn)

        let selection = DictationInputDeviceSelectionPolicy.selection(
            defaultInput: airPodsInput,
            defaultOutput: airPodsOutput,
            availableInputs: [airPodsInput, macBookMic]
        )

        assertEqual(selection.selectedInput, macBookMic, "AirPods mic should fall back to the local MacBook mic")
        assertTrue(selection.didOverrideDefault, "selection should report that the system default was overridden")
        assertEqual(selection.reason, .preferredBuiltInForBluetoothHeadset, "selection reason should explain the Bluetooth fallback")
    }

    runSuite("DictationInputDeviceSelectionPolicy prefers MacBook mic over display mic") {
        let airPodsInput = device(1, "AirPods Max", .bluetooth)
        let airPodsOutput = device(2, "AirPods Max", .bluetooth, inputChannels: 0)
        let displayMic = device(3, "Studio Display Microphone", .builtIn)
        let macBookMic = device(4, "MacBook Pro Microphone", .builtIn)

        let selection = DictationInputDeviceSelectionPolicy.selection(
            defaultInput: airPodsInput,
            defaultOutput: airPodsOutput,
            availableInputs: [airPodsInput, displayMic, macBookMic]
        )

        assertEqual(selection.selectedInput, macBookMic, "MacBook mic should be the first built-in fallback")
    }

    runSuite("DictationInputDeviceSelectionPolicy keeps Bluetooth input when output is not Bluetooth") {
        let airPodsInput = device(1, "Justin's AirPods Pro", .bluetooth)
        let speakers = device(2, "MacBook Pro Speakers", .builtIn, inputChannels: 0)
        let macBookMic = device(3, "MacBook Pro Microphone", .builtIn)

        let selection = DictationInputDeviceSelectionPolicy.selection(
            defaultInput: airPodsInput,
            defaultOutput: speakers,
            availableInputs: [airPodsInput, macBookMic]
        )

        assertEqual(selection.selectedInput, airPodsInput, "non-Bluetooth output should preserve the user's chosen input")
        assertFalse(selection.didOverrideDefault, "selection should not override when headset playback is not active")
    }

    runSuite("DictationInputDeviceSelectionPolicy keeps USB microphones") {
        let usbMic = device(1, "Shure MV7", .usb)
        let airPodsOutput = device(2, "Justin's AirPods Pro", .bluetooth, inputChannels: 0)
        let macBookMic = device(3, "MacBook Pro Microphone", .builtIn)

        let selection = DictationInputDeviceSelectionPolicy.selection(
            defaultInput: usbMic,
            defaultOutput: airPodsOutput,
            availableInputs: [usbMic, macBookMic]
        )

        assertEqual(selection.selectedInput, usbMic, "USB mics should stay selected")
        assertEqual(selection.reason, .defaultIsSafe, "USB mics do not need the Bluetooth fallback")
    }

    runSuite("DictationInputDeviceSelectionPolicy keeps AirPods when no built-in fallback exists") {
        let airPodsInput = device(1, "Justin's AirPods Pro", .bluetooth)
        let airPodsOutput = device(2, "Justin's AirPods Pro", .bluetooth, inputChannels: 0)

        let selection = DictationInputDeviceSelectionPolicy.selection(
            defaultInput: airPodsInput,
            defaultOutput: airPodsOutput,
            availableInputs: [airPodsInput]
        )

        assertEqual(selection.selectedInput, airPodsInput, "without a local mic fallback, dictation should still work")
        assertEqual(selection.reason, .noBuiltInFallbackAvailable, "missing fallback should be explicit")
    }
}

private func device(
    _ id: UInt32,
    _ name: String,
    _ transport: DictationAudioTransport,
    inputChannels: UInt32 = 1
) -> DictationAudioDevice {
    DictationAudioDevice(
        id: id,
        name: name,
        transport: transport,
        inputChannelCount: inputChannels
    )
}
