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
            DictationPersistentInputRefreshPolicy.shouldDefer(
                isDictationActive: true,
                isMeetingCaptureActive: false
            ),
            "persistent input maintenance must not interrupt a live dictation graph"
        )
        assertTrue(
            DictationPersistentInputRefreshPolicy.shouldDefer(
                isDictationActive: false,
                isMeetingCaptureActive: true
            ),
            "persistent input maintenance must not write the Mac-wide default mid-meeting"
        )
        assertTrue(
            DictationPersistentInputRefreshPolicy.shouldDefer(
                isDictationActive: true,
                isMeetingCaptureActive: true
            ),
            "either live capture path is enough to defer the system-default write"
        )
        assertFalse(
            DictationPersistentInputRefreshPolicy.shouldDefer(
                isDictationActive: false,
                isMeetingCaptureActive: false
            ),
            "persistent input maintenance should resume after dictation and meeting capture stop"
        )
    }

    runSuite("Persistent input maintenance protects external microphone capture") {
        assertTrue(
            DictationPersistentInputRefreshPolicy.shouldDefer(
                isDictationActive: false,
                isMeetingCaptureActive: false,
                externalInputActive: true
            ),
            "another app recording must block global input changes even when Transcripted is idle"
        )
        assertTrue(
            DictationPersistentInputRefreshPolicy.shouldDefer(
                isDictationActive: false,
                isMeetingCaptureActive: false,
                externalInputActive: nil
            ),
            "a failed activity read must not authorize a global input change"
        )
        assertFalse(
            DictationPersistentInputRefreshPolicy.shouldDefer(
                isDictationActive: false,
                isMeetingCaptureActive: false,
                externalInputActive: false
            ),
            "preference maintenance can resume once external capture ends"
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

    runSuite("PinnedDictationInputPolicy uses a wired or USB mic when a Mac has no built-in mic") {
        let airPodsInput = DictationAudioDevice(id: 1, name: "AirPods Pro", transport: .bluetooth, inputChannelCount: 1, uid: "airpods")
        let airPodsOutput = DictationAudioDevice(id: 2, name: "AirPods Pro", transport: .bluetooth, inputChannelCount: 0, uid: "airpods-out")
        let webcam = DictationAudioDevice(id: 3, name: "Logitech C920 Camera", transport: .other, inputChannelCount: 1, uid: "c920")
        let usbMic = DictationAudioDevice(id: 4, name: "Yeti Stereo Microphone", transport: .usb, inputChannelCount: 2, uid: "yeti")
        let loopback = DictationAudioDevice(id: 5, name: "BlackHole 2ch", transport: .virtual, inputChannelCount: 2, uid: "blackhole")
        let inputs = [airPodsInput, webcam, usbMic, loopback]
        let automatic = DictationInputDeviceSelectionPolicy.selection(
            defaultInput: airPodsInput,
            defaultOutput: airPodsOutput,
            availableInputs: inputs,
            prefersBuiltInBluetoothInput: true
        )
        assertEqual(automatic.reason, .noBuiltInFallbackAvailable, "a Mac mini has no built-in fallback")

        let pinned = PinnedDictationInputPolicy.selection(automatic: automatic, availableInputs: inputs, preferredUID: nil)
        assertEqual(pinned.selectedInput, usbMic, "a USB mic beats the AirPods and other external mics")
        assertEqual(pinned.reason, .preferredExternalForBluetoothHeadset, "the external pick should be explicit")
        assertEqual(pinned.defaultInput, airPodsInput, "the macOS input stays what it was")

        let noUSB = PinnedDictationInputPolicy.selection(automatic: automatic, availableInputs: [airPodsInput, webcam, loopback], preferredUID: nil)
        assertEqual(noUSB.selectedInput, webcam, "a wired webcam mic still beats the AirPods")

        let onlyVirtual = PinnedDictationInputPolicy.selection(automatic: automatic, availableInputs: [airPodsInput, loopback], preferredUID: nil)
        assertEqual(onlyVirtual, automatic, "a virtual loopback device never stands in for a real mic")
    }

    runSuite("PinnedDictationInputPolicy honors a chosen mic instead of a Bluetooth headset") {
        let airPodsInput = DictationAudioDevice(id: 1, name: "AirPods Pro", transport: .bluetooth, inputChannelCount: 1, uid: "airpods")
        let airPodsOutput = DictationAudioDevice(id: 2, name: "AirPods Pro", transport: .bluetooth, inputChannelCount: 0, uid: "airpods-out")
        let macMic = DictationAudioDevice(id: 3, name: "MacBook Pro Microphone", transport: .builtIn, inputChannelCount: 1, uid: "mac")
        let usbMic = DictationAudioDevice(id: 4, name: "Shure MV7", transport: .usb, inputChannelCount: 1, uid: "mv7")
        let inputs = [airPodsInput, macMic, usbMic]
        let automatic = DictationInputDeviceSelectionPolicy.selection(
            defaultInput: airPodsInput,
            defaultOutput: airPodsOutput,
            availableInputs: inputs,
            prefersBuiltInBluetoothInput: true
        )
        assertEqual(automatic.selectedInput, macMic, "the automatic pick is the Mac mic")

        let chosen = PinnedDictationInputPolicy.selection(automatic: automatic, availableInputs: inputs, preferredUID: "mv7")
        assertEqual(chosen.selectedInput, usbMic, "the mic the user chose wins over the Mac mic")
        assertEqual(chosen.reason, .preferredUserChosenForBluetoothHeadset, "the chosen pick should be explicit")

        let unplugged = PinnedDictationInputPolicy.selection(automatic: automatic, availableInputs: [airPodsInput, macMic], preferredUID: "mv7")
        assertEqual(unplugged, automatic, "an unplugged chosen mic falls back to the automatic pick")

        let headsetChosen = PinnedDictationInputPolicy.selection(automatic: automatic, availableInputs: inputs, preferredUID: "airpods")
        assertEqual(headsetChosen, automatic, "a saved Bluetooth pick never puts the headset back in call mode")
    }

    runSuite("Dictation skips a closed MacBook's mic, including a chosen one") {
        let airPodsInput = DictationAudioDevice(id: 1, name: "AirPods Pro", transport: .bluetooth, inputChannelCount: 1, uid: "airpods")
        let macMic = DictationAudioDevice(id: 3, name: "MacBook Pro Microphone", transport: .builtIn, inputChannelCount: 1, uid: "mac")
        let displayMic = DictationAudioDevice(id: 5, name: "Studio Display Microphone", transport: .usb, inputChannelCount: 1, uid: "display")
        let usbMic = DictationAudioDevice(id: 4, name: "Shure MV7", transport: .usb, inputChannelCount: 1, uid: "mv7")

        let lidClosed = DictationInputDeviceSelectionPolicy.selection(
            defaultInput: airPodsInput,
            defaultOutput: airPodsInput,
            availableInputs: [airPodsInput, macMic, displayMic],
            prefersBuiltInBluetoothInput: true,
            lidClosed: true
        )
        assertEqual(lidClosed.selectedInput, displayMic, "a closed lid picks the display mic, not the dead MacBook mic")

        let onlyDeadMic = DictationInputDeviceSelectionPolicy.selection(
            defaultInput: airPodsInput,
            defaultOutput: airPodsInput,
            availableInputs: [airPodsInput, macMic, usbMic],
            prefersBuiltInBluetoothInput: true,
            lidClosed: true
        )
        assertEqual(onlyDeadMic.reason, .noBuiltInFallbackAvailable, "the dead mic is not a fallback")
        let pinned = PinnedDictationInputPolicy.selection(
            automatic: onlyDeadMic,
            availableInputs: [airPodsInput, macMic, usbMic],
            preferredUID: "mac",
            lidClosed: true
        )
        assertEqual(pinned.selectedInput, usbMic, "a chosen MacBook mic is skipped while the lid is closed")
        assertFalse(
            DictationInputDeviceSelectionPolicy.isLidMicrophone(
                DictationAudioDevice(id: 9, name: "External Microphone", transport: .builtIn, inputChannelCount: 1)
            ),
            "the headphone-jack mic works with the lid closed"
        )
    }

    runSuite("PinnedDictationInputPolicy only needs the recorder to skip a Bluetooth input") {
        let airPodsInput = DictationAudioDevice(id: 1, name: "AirPods Pro", transport: .bluetooth, inputChannelCount: 1, uid: "airpods")
        let macMic = DictationAudioDevice(id: 3, name: "MacBook Pro Microphone", transport: .builtIn, inputChannelCount: 1, uid: "mac")
        let usbMic = DictationAudioDevice(id: 4, name: "Shure MV7", transport: .usb, inputChannelCount: 1, uid: "mv7")

        let skipsHeadset = DictationInputDeviceSelectionPolicy.selection(
            defaultInput: airPodsInput, defaultOutput: airPodsInput,
            availableInputs: [airPodsInput, macMic], prefersBuiltInBluetoothInput: true
        )
        assertTrue(PinnedDictationInputPolicy.recorderIsNeeded(for: skipsHeadset), "skipping a Bluetooth input needs the recorder")

        let headsetOnly = DictationInputDeviceSelectionPolicy.selection(
            defaultInput: airPodsInput, defaultOutput: airPodsInput,
            availableInputs: [airPodsInput], prefersBuiltInBluetoothInput: true
        )
        assertFalse(PinnedDictationInputPolicy.recorderIsNeeded(for: headsetOnly), "recording the headset itself uses the engine")

        let usbDefault = DictationInputDeviceSelectionPolicy.selection(
            defaultInput: usbMic, defaultOutput: airPodsInput,
            availableInputs: [airPodsInput, macMic, usbMic], prefersBuiltInBluetoothInput: true
        )
        assertFalse(PinnedDictationInputPolicy.recorderIsNeeded(for: usbDefault), "a safe macOS input uses the engine")
    }

    runSuite("PinnedDictationInputPolicy follows macOS when its input is already a safe mic") {
        let usbMic = DictationAudioDevice(id: 4, name: "Shure MV7", transport: .usb, inputChannelCount: 1, uid: "mv7")
        let macMic = DictationAudioDevice(id: 3, name: "MacBook Pro Microphone", transport: .builtIn, inputChannelCount: 1, uid: "mac")
        let automatic = DictationInputDeviceSelectionPolicy.selection(
            defaultInput: macMic,
            defaultOutput: nil,
            availableInputs: [macMic, usbMic],
            prefersBuiltInBluetoothInput: true
        )
        assertEqual(
            PinnedDictationInputPolicy.selection(automatic: automatic, availableInputs: [macMic, usbMic], preferredUID: "mv7"),
            automatic,
            "a live macOS choice of a non-Bluetooth mic is followed"
        )

        let airPodsInput = DictationAudioDevice(id: 1, name: "AirPods Pro", transport: .bluetooth, inputChannelCount: 1, uid: "airpods")
        let followsHeadset = DictationInputDeviceSelectionPolicy.selection(
            defaultInput: airPodsInput,
            defaultOutput: nil,
            availableInputs: [airPodsInput, usbMic],
            prefersBuiltInBluetoothInput: false
        )
        assertEqual(
            PinnedDictationInputPolicy.selection(automatic: followsHeadset, availableInputs: [airPodsInput, usbMic], preferredUID: "mv7"),
            followsHeadset,
            "when the user asked to record the macOS input, the headset is kept"
        )
    }

    runSuite("DictationInputDeviceSelectionPolicy follows the selected AirPods mic by default") {
        let headset = device(1, "Bluetooth Input", .bluetooth)
        let output = device(2, "Bluetooth Output", .bluetooth, inputChannels: 0)
        let builtIn = device(3, "Built-In Microphone", .builtIn)
        let display = device(4, "Studio Display Microphone", .builtIn)

        for defaultOutput in [output, nil] {
            let selection = DictationInputDeviceSelectionPolicy.selection(
                defaultInput: headset,
                defaultOutput: defaultOutput,
                availableInputs: [headset, builtIn, display]
            )
            assertEqual(selection.selectedInput, headset, "normal dictation must use the chosen headset even when a local mic is listed")
            assertFalse(selection.didOverrideDefault, "Bluetooth playback must not silently change the microphone")
            assertEqual(selection.reason, .defaultIsSafe, "following the selected mic is the normal route")
        }
    }

    runSuite("DictationInputDeviceSelectionPolicy chooses MacBook mic for AirPods input/output") {
        let airPodsInput = device(1, "Justin's AirPods Pro", .bluetooth)
        let airPodsOutput = device(2, "Justin's AirPods Pro", .bluetooth, inputChannels: 0)
        let macBookMic = device(3, "MacBook Pro Microphone", .builtIn)

        let selection = DictationInputDeviceSelectionPolicy.selection(
            defaultInput: airPodsInput,
            defaultOutput: airPodsOutput,
            availableInputs: [airPodsInput, macBookMic],
            prefersBuiltInBluetoothInput: true
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
            availableInputs: [airPodsInput, displayMic, macBookMic],
            prefersBuiltInBluetoothInput: true
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
            prefersBuiltInBluetoothInput: true,
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
            prefersBuiltInBluetoothInput: true,
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
            prefersBuiltInBluetoothInput: true,
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
            prefersBuiltInBluetoothInput: true,
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
            prefersBuiltInBluetoothInput: true,
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
            availableInputs: [airPodsInput, macBookMic],
            prefersBuiltInBluetoothInput: true
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
            availableInputs: [usbMic, macBookMic],
            prefersBuiltInBluetoothInput: true
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
            availableInputs: [airPodsInput],
            prefersBuiltInBluetoothInput: true
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

    runSuite("Dictation input binding follows the selected device even after a prior override") {
        let builtIn = device(10, "Built-in microphone", .builtIn)
        let headset = device(20, "Bluetooth headset", .bluetooth)
        let usb = device(30, "USB microphone", .usb)
        for selection in [
            DictationInputDeviceSelection(defaultInput: headset, selectedInput: builtIn,
                defaultOutput: headset, reason: .preferredBuiltInForBluetoothHeadset),
            DictationInputDeviceSelection(defaultInput: usb, selectedInput: usb,
                defaultOutput: headset, reason: .defaultIsSafe),
            DictationInputDeviceSelection(defaultInput: headset, selectedInput: headset,
                defaultOutput: headset, reason: .builtInFallbackSuppressedForRecoveryAttempt)
        ] {
            var boundID = selection.didOverrideDefault ? headset.id : builtIn.id
            var writes: [UInt32] = []
            do {
                let changed = try DictationInputDeviceBindingPolicy.apply(
                    selection: selection,
                    currentDeviceID: { boundID },
                    setDeviceID: { writes.append($0); boundID = $0 }
                )
                assertTrue(changed, "a stale app-local binding must move to the selected microphone")
                assertEqual(boundID, selection.selectedInput.id, "selected default must replace a prior pinned fallback")
                assertEqual(writes, [selection.selectedInput.id], "bind exactly once per device transition")
            } catch {
                assertTrue(false, "a successful local bind should be accepted: \(error)")
            }
        }
    }

    runSuite("Dictation input binding does not churn a settled microphone") {
        let builtIn = device(10, "Built-in microphone", .builtIn)
        let headset = device(20, "Bluetooth headset", .bluetooth)
        let selection = DictationInputDeviceSelection(defaultInput: headset, selectedInput: builtIn,
            defaultOutput: headset, reason: .preferredBuiltInForBluetoothHeadset)
        var writes = 0
        do {
            let changed = try DictationInputDeviceBindingPolicy.apply(
                selection: selection,
                currentDeviceID: { builtIn.id },
                setDeviceID: { _ in writes += 1 }
            )
            assertFalse(changed, "readiness polling must not repeatedly set the same device")
            assertEqual(writes, 0, "a settled fallback should avoid native route writes")
        } catch {
            assertTrue(false, "a verified binding should succeed")
        }
    }

    runSuite("Dictation input binding rejects driver failures and unconfirmed settled selections") {
        let builtIn = device(10, "Built-in microphone", .builtIn)
        let headset = device(20, "Bluetooth headset", .bluetooth)
        let selection = DictationInputDeviceSelection(defaultInput: headset, selectedInput: builtIn,
            defaultOutput: headset, reason: .preferredBuiltInForBluetoothHeadset)
        let driverFailure = NSError(domain: "SyntheticDriver", code: 123)
        do {
            try DictationInputDeviceBindingPolicy.apply(
                selection: selection,
                currentDeviceID: { headset.id },
                setDeviceID: { _ in throw driverFailure }
            )
            assertTrue(false, "driver rejection must never produce successful readiness")
        } catch {
            assertEqual((error as NSError).domain, driverFailure.domain, "preserve driver error for local diagnostics")
        }
        for observedID in [headset.id, UInt32(0)] {
            do {
                try DictationInputDeviceBindingPolicy.verify(selectedDeviceID: builtIn.id, boundDeviceID: observedID)
                assertTrue(false, "a route that moved again during settling must not become ready")
            } catch {
                assertEqual(error as? DictationInputDeviceBindingError, .selectedDeviceNotBound,
                    "settled snapshot must verify physical binding again")
            }
        }
    }

    runSuite("Dictation input binding waits for a successful USB command to settle") {
        // Synthetic C920-style timing, not a recording from physical hardware.
        let builtIn = device(10, "Built-in microphone", .builtIn)
        let webcam = device(30, "Logitech HD Pro Webcam C920", .usb)
        let selection = DictationInputDeviceSelectionPolicy.selection(
            defaultInput: webcam, defaultOutput: builtIn, availableInputs: [builtIn, webcam]
        )
        assertEqual(selection.selectedInput, webcam, "normal dictation must follow the selected USB input")
        for initialID in [builtIn.id, UInt32(0)] {
            for settledID in [webcam.id, builtIn.id, UInt32(0)] {
                var observedID = initialID
                var writes: [UInt32] = []
                var reachedSettle = false
                var ready = false
                var bindingError: DictationInputDeviceBindingError?
                do {
                    let didBind = try DictationInputDeviceBindingPolicy.apply(
                        selection: selection,
                        currentDeviceID: { observedID },
                        setDeviceID: { writes.append($0) } // Success; device ID is still stale.
                    )
                    // Model audioInputSnapshot's delayed read without a wall-clock sleep.
                    if didBind {
                        reachedSettle = true
                        observedID = settledID
                        try DictationInputDeviceBindingPolicy.verify(
                            selectedDeviceID: webcam.id, boundDeviceID: observedID
                        )
                    }
                    ready = true
                } catch {
                    bindingError = error as? DictationInputDeviceBindingError
                }
                assertEqual(writes, [webcam.id], "request the selected USB microphone once")
                assertTrue(reachedSettle, "successful route commands must reach the delayed verification")
                assertEqual(ready, settledID == webcam.id, "only the selected settled device can become ready")
                assertEqual(bindingError, settledID == webcam.id ? nil : .selectedDeviceNotBound,
                    "stale or disconnected inputs must still fail after settling")
            }
        }
    }

    runSuite("Dictation input binding rejects an unknown target without writing to the driver") {
        let unknown = device(0, "Unavailable input", .usb)
        let selection = DictationInputDeviceSelection(defaultInput: unknown, selectedInput: unknown,
            defaultOutput: nil, reason: .defaultIsSafe)
        for initialID in [UInt32(0), UInt32(10)] {
            var writes = 0
            do {
                try DictationInputDeviceBindingPolicy.apply(
                    selection: selection, currentDeviceID: { initialID },
                    setDeviceID: { _ in writes += 1 }
                )
                assertTrue(false, "an unknown selected input cannot become ready")
            } catch {
                assertEqual(error as? DictationInputDeviceBindingError, .selectedDeviceNotBound,
                    "unknown targets must fail closed")
            }
            assertEqual(writes, 0, "never ask AUHAL to bind the unknown device ID")
        }
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
