import Foundation

func testDictationInputDeviceSelectionPolicy() {
    runSuite("DictationPersistentInputPreferences defaults off and persists explicit opt-in") {
        let suiteName = "DictationPersistentInputPreferencesTests-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defaults.removePersistentDomain(forName: suiteName)
        defer { defaults.removePersistentDomain(forName: suiteName) }

        assertFalse(
            DictationPersistentInputPreferences.isEnabled(userDefaults: defaults),
            "keeping a Mac-wide microphone active must remain explicit opt-in"
        )
        DictationPersistentInputPreferences.setEnabled(true, userDefaults: defaults)
        assertTrue(
            DictationPersistentInputPreferences.isEnabled(userDefaults: defaults),
            "the faster Bluetooth start preference should persist"
        )
        DictationPersistentInputPreferences.setPreferredDeviceUID("usb-mic-uid", userDefaults: defaults)
        assertEqual(
            DictationPersistentInputPreferences.preferredDeviceUID(userDefaults: defaults),
            "usb-mic-uid",
            "the preferred microphone should persist by stable CoreAudio UID"
        )
        let marker = DictationPersistentInputPreferences.RecoveryMarker(
            selectedUID: "usb-mic-uid",
            previousUID: "system-mic-uid"
        )
        DictationPersistentInputPreferences.setRecoveryMarker(marker, userDefaults: defaults)
        assertEqual(
            DictationPersistentInputPreferences.recoveryMarker(userDefaults: defaults),
            marker,
            "unclean exits should leave a durable restoration obligation"
        )
    }

    runSuite("DictationPersistentInputRecoveryPolicy adopts, restores, or clears crash markers") {
        let marker = DictationPersistentInputPreferences.RecoveryMarker(
            selectedUID: "selected",
            previousUID: "previous"
        )
        assertEqual(
            DictationPersistentInputRecoveryPolicy.action(
                preferenceEnabled: true,
                currentUID: "selected",
                marker: marker,
                availableUIDs: ["selected", "previous"]
            ),
            .adopt,
            "a relaunched opted-in app should reclaim the restoration obligation"
        )
        assertEqual(
            DictationPersistentInputRecoveryPolicy.action(
                preferenceEnabled: false,
                currentUID: "selected",
                marker: marker,
                availableUIDs: ["selected", "previous"]
            ),
            .restore,
            "a disabled preference should restore the prior microphone on relaunch"
        )
        assertEqual(
            DictationPersistentInputRecoveryPolicy.action(
                preferenceEnabled: true,
                currentUID: "user-changed",
                marker: marker,
                availableUIDs: ["selected", "previous", "user-changed"]
            ),
            .clear,
            "an external microphone change should cancel stale restoration ownership"
        )
        assertEqual(
            DictationPersistentInputRecoveryPolicy.action(
                preferenceEnabled: false,
                currentUID: "selected",
                marker: marker,
                availableUIDs: ["selected"]
            ),
            .preserve,
            "a disconnected previous microphone must keep its restoration obligation"
        )
    }

    runSuite("DictationPersistentInputRuntimePolicy preserves external microphone choices") {
        assertEqual(
            DictationPersistentInputRuntimePolicy.action(
                preferenceEnabled: true,
                runtimeOwnershipRelinquished: false,
                defaultInputChanged: true,
                deviceListChanged: true,
                currentInputID: "airpods",
                desiredInputID: "built-in",
                lastMaintainedInputID: "built-in",
                lastMaintainedInputIsAvailable: true
            ),
            .preserveExternalSelection,
            "an external change away from Transcripted's available maintained input should relinquish ownership even during profile churn"
        )
        assertEqual(
            DictationPersistentInputRuntimePolicy.action(
                preferenceEnabled: true,
                runtimeOwnershipRelinquished: false,
                defaultInputChanged: true,
                deviceListChanged: true,
                currentInputID: "built-in",
                desiredInputID: "usb",
                lastMaintainedInputID: "missing-usb",
                lastMaintainedInputIsAvailable: false
            ),
            .reconcile,
            "a disconnected maintained device should allow normal fallback and reconnect handling"
        )
        assertEqual(
            DictationPersistentInputRuntimePolicy.action(
                preferenceEnabled: true,
                runtimeOwnershipRelinquished: false,
                defaultInputChanged: true,
                deviceListChanged: false,
                currentInputID: "built-in",
                desiredInputID: "built-in",
                lastMaintainedInputID: "built-in",
                lastMaintainedInputIsAvailable: true
            ),
            .reconcile,
            "Transcripted's own completed input write should reconcile without relinquishing"
        )
        assertEqual(
            DictationPersistentInputRuntimePolicy.action(
                preferenceEnabled: true,
                runtimeOwnershipRelinquished: true,
                defaultInputChanged: false,
                deviceListChanged: true,
                currentInputID: "airpods",
                desiredInputID: "built-in",
                lastMaintainedInputID: Optional<String>.none,
                lastMaintainedInputIsAvailable: false
            ),
            .preserveExternalSelection,
            "unrelated topology churn must not silently reclaim runtime ownership"
        )
        assertEqual(
            DictationPersistentInputRuntimePolicy.action(
                preferenceEnabled: false,
                runtimeOwnershipRelinquished: true,
                defaultInputChanged: true,
                deviceListChanged: false,
                currentInputID: "airpods",
                desiredInputID: "built-in",
                lastMaintainedInputID: "built-in",
                lastMaintainedInputIsAvailable: true
            ),
            .reconcile,
            "disabling the preference should still run normal restoration cleanup"
        )
    }

    runSuite("DictationPersistentInputRefreshPolicy defers system input writes during dictation") {
        assertTrue(
            DictationPersistentInputRefreshPolicy.shouldSchedule(
                preferenceChanged: true,
                preferenceEnabled: false,
                hasRecoveryMarker: false
            ),
            "a preference notification must schedule deferred cleanup even when the new preference is disabled"
        )
        assertFalse(
            DictationPersistentInputRefreshPolicy.shouldSchedule(
                preferenceChanged: false,
                preferenceEnabled: false,
                hasRecoveryMarker: false
            ),
            "unrelated topology noise should remain idle when there is no preference or recovery work"
        )
        assertTrue(
            DictationPersistentInputRefreshPolicy.shouldDefer(isDictationActive: true),
            "persistent input maintenance must not interrupt a live dictation graph"
        )
        assertFalse(
            DictationPersistentInputRefreshPolicy.shouldDefer(isDictationActive: false),
            "persistent input maintenance should resume after dictation stops"
        )
    }

    runSuite("DictationPreferredInputPolicy uses preferred USB then automatic fallback") {
        let bluetooth = DictationAudioDevice(id: 1, name: "AirPods", transport: .bluetooth, inputChannelCount: 1, uid: "airpods")
        let macMic = DictationAudioDevice(id: 2, name: "MacBook Pro Microphone", transport: .builtIn, inputChannelCount: 1, uid: "mac")
        let usbMic = DictationAudioDevice(id: 3, name: "Studio USB Mic", transport: .usb, inputChannelCount: 1, uid: "usb")

        assertEqual(
            DictationPreferredInputPolicy.input(preferredUID: "usb", availableInputs: [bluetooth, macMic, usbMic], automaticFallback: macMic),
            usbMic,
            "an available preferred USB microphone should win"
        )
        assertEqual(
            DictationPreferredInputPolicy.input(preferredUID: "missing", availableInputs: [bluetooth, macMic], automaticFallback: macMic),
            macMic,
            "an unavailable preferred microphone should fall back automatically"
        )
        assertEqual(
            DictationPreferredInputPolicy.input(preferredUID: "airpods", availableInputs: [bluetooth, macMic], automaticFallback: macMic),
            macMic,
            "the faster-start preference should not silently choose a Bluetooth headset microphone"
        )
    }

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

    runSuite("DictationVoiceProcessingRoutePolicy avoids VPIO on split Bluetooth output") {
        let bluetoothOutput = device(1, "Bluetooth Output", .bluetooth, inputChannels: 0)
        let bluetoothInput = device(2, "Bluetooth Input", .bluetooth)
        let builtInInput = device(3, "Built-In Microphone", .builtIn)
        let usbInput = device(4, "USB Microphone", .usb)
        let builtInOutput = device(5, "Built-In Speakers", .builtIn, inputChannels: 0)

        func selection(
            input: DictationAudioDevice,
            output: DictationAudioDevice?
        ) -> DictationInputDeviceSelection {
            DictationInputDeviceSelection(
                defaultInput: input,
                selectedInput: input,
                defaultOutput: output,
                reason: .defaultIsSafe
            )
        }

        assertEqual(
            DictationVoiceProcessingRoutePolicy.decision(
                requested: true,
                selection: selection(input: builtInInput, output: bluetoothOutput)
            ),
            .deferredForSplitBluetoothOutput,
            "built-in mic plus Bluetooth output should avoid call-mode route renegotiation"
        )
        assertEqual(
            DictationVoiceProcessingRoutePolicy.decision(
                requested: true,
                selection: selection(input: usbInput, output: bluetoothOutput)
            ),
            .deferredForSplitBluetoothOutput,
            "USB mic plus Bluetooth output should also stay on the regular input graph"
        )
        assertEqual(
            DictationVoiceProcessingRoutePolicy.decision(
                requested: true,
                selection: selection(input: bluetoothInput, output: bluetoothOutput)
            ),
            .enabled,
            "matched Bluetooth voice routes should preserve the explicit VPIO preference"
        )
        assertEqual(
            DictationVoiceProcessingRoutePolicy.decision(
                requested: true,
                selection: selection(input: builtInInput, output: builtInOutput)
            ),
            .enabled,
            "non-Bluetooth routes should preserve the explicit VPIO preference"
        )
        assertEqual(
            DictationVoiceProcessingRoutePolicy.decision(
                requested: false,
                selection: selection(input: builtInInput, output: bluetoothOutput)
            ),
            .disabledByPreference,
            "the route policy should never override an explicitly disabled preference"
        )
        assertEqual(
            DictationVoiceProcessingRoutePolicy.decision(requested: true, selection: nil),
            .enabled,
            "unknown routes should not silently discard an explicit preference"
        )
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
