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

    runSuite("DictationInputDeviceSelectionPolicy can suppress built-in fallback for recovery starts") {
        let airPodsInput = device(1, "Justin's AirPods Pro", .bluetooth)
        let airPodsOutput = device(2, "Justin's AirPods Pro", .bluetooth, inputChannels: 0)
        let macBookMic = device(3, "MacBook Pro Microphone", .builtIn)

        let selection = DictationInputDeviceSelectionPolicy.selection(
            defaultInput: airPodsInput,
            defaultOutput: airPodsOutput,
            availableInputs: [airPodsInput, macBookMic],
            allowsBuiltInBluetoothFallback: false
        )

        assertEqual(selection.selectedInput, airPodsInput, "recovery starts should get one chance to use the matched Bluetooth route")
        assertFalse(selection.didOverrideDefault, "suppressed fallback should not force the hybrid built-in/Bluetooth route")
        assertEqual(selection.reason, .builtInFallbackSuppressedForRecoveryAttempt, "selection reason should make the recovery fallback queryable")
    }

    runSuite("DictationInputDeviceSelectionPolicy suppresses fallback before ranking built-in candidates") {
        let headsetInput = device(1, "Bluetooth Headset", .bluetooth)
        let headsetOutput = device(2, "Bluetooth Output", .bluetooth, inputChannels: 0)
        let displayMic = device(3, "External Built-In Microphone", .builtIn)
        let builtInMic = device(4, "Built-In Microphone", .builtIn)

        let selection = DictationInputDeviceSelectionPolicy.selection(
            defaultInput: headsetInput,
            defaultOutput: headsetOutput,
            availableInputs: [headsetInput, displayMic, builtInMic],
            allowsBuiltInBluetoothFallback: false
        )

        assertEqual(selection.selectedInput, headsetInput, "suppressed fallback should keep the matched Bluetooth input even when better built-in mics are visible")
        assertFalse(selection.didOverrideDefault, "suppressed fallback should not rank or select built-in candidates")
        assertEqual(selection.reason, .builtInFallbackSuppressedForRecoveryAttempt, "suppressed fallback should keep its explicit recovery reason")
    }

    runSuite("DictationInputDeviceSelectionPolicy suppresses fallback when Bluetooth output is unknown") {
        let headsetInput = device(1, "Bluetooth Hands-Free", .bluetooth)
        let builtInMic = device(2, "Built-In Microphone", .builtIn)

        let selection = DictationInputDeviceSelectionPolicy.selection(
            defaultInput: headsetInput,
            defaultOutput: nil,
            availableInputs: [headsetInput, builtInMic],
            allowsBuiltInBluetoothFallback: false
        )

        assertEqual(selection.selectedInput, headsetInput, "recovery starts should not force a built-in override when output lookup fails")
        assertEqual(selection.reason, .builtInFallbackSuppressedForRecoveryAttempt, "missing output plus suppressed fallback should still be queryable")
    }

    runSuite("DictationInputDeviceSelectionPolicy suppression flag does not affect safe USB inputs") {
        let usbMic = device(1, "USB Microphone", .usb)
        let headsetOutput = device(2, "Bluetooth Output", .bluetooth, inputChannels: 0)
        let builtInMic = device(3, "Built-In Microphone", .builtIn)

        let selection = DictationInputDeviceSelectionPolicy.selection(
            defaultInput: usbMic,
            defaultOutput: headsetOutput,
            availableInputs: [usbMic, builtInMic],
            allowsBuiltInBluetoothFallback: false
        )

        assertEqual(selection.selectedInput, usbMic, "non-Bluetooth mics should stay selected regardless of the recovery fallback flag")
        assertEqual(selection.reason, .defaultIsSafe, "safe defaults should not be labeled as suppressed Bluetooth recovery")
    }

    runSuite("DictationInputDeviceSelectionPolicy suppression flag does not affect safe Bluetooth playback") {
        let headsetInput = device(1, "Bluetooth Headset", .bluetooth)
        let speakers = device(2, "Built-In Speakers", .builtIn, inputChannels: 0)
        let builtInMic = device(3, "Built-In Microphone", .builtIn)

        let selection = DictationInputDeviceSelectionPolicy.selection(
            defaultInput: headsetInput,
            defaultOutput: speakers,
            availableInputs: [headsetInput, builtInMic],
            allowsBuiltInBluetoothFallback: false
        )

        assertEqual(selection.selectedInput, headsetInput, "Bluetooth input is already safe when playback is not on Bluetooth")
        assertEqual(selection.reason, .defaultIsSafe, "safe Bluetooth routes should not be reported as suppressed recovery attempts")
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

    runSuite("DictationInputDeviceSelectionPolicy classifies non-USB external mics") {
        assertEqual(
            DictationInputDeviceSelectionPolicy.deviceClass(forName: "Logitech C920 Camera Microphone"),
            "external",
            "webcam mics should not collapse to unknown"
        )
        assertEqual(
            DictationInputDeviceSelectionPolicy.deviceClass(forName: "Universal Audio Interface"),
            "external",
            "audio interface names should produce a stable route class"
        )
    }

    runSuite("DictationInputDeviceSelectionPolicy preserves aggregate and virtual route classes") {
        assertEqual(
            DictationInputDeviceSelectionPolicy.deviceClass(forName: "Multi-Output Aggregate", transport: .aggregate),
            "aggregate",
            "aggregate devices should be visible in route-shape analytics"
        )
        assertEqual(
            DictationInputDeviceSelectionPolicy.deviceClass(forName: "BlackHole 2ch", transport: .virtual),
            "virtual",
            "virtual devices should be visible in route-shape analytics"
        )
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
