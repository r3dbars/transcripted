import Foundation

func testMicrophoneChoiceTransitions() {
    runSuite("Microphone choice changes follow the current devices across a headset reconnect") {
        let fixture = MicrophoneChoiceTransitionFixture()
        defer { fixture.cleanUp() }
        // A saved UID from the older picker must not leak into Automatic or
        // Same as macOS Sound settings after either choice is persisted.
        DictationPersistentInputPreferences.setPreferredDeviceUID("old-usb", userDefaults: fixture.defaults)
        MicrophoneChoicePreferences.setChoice(.automatic, userDefaults: fixture.defaults)
        assertEqual(fixture.selection(defaultInput: fixture.mac).selectedInput, fixture.mac)

        MicrophoneChoicePreferences.setChoice(.macOSInput, userDefaults: fixture.defaults)
        let firstConnection = fixture.headset(id: 20)
        assertEqual(fixture.selection(defaultInput: firstConnection).selectedInput, firstConnection)
        assertEqual(fixture.selection(defaultInput: fixture.mac).selectedInput, fixture.mac, "disconnect follows the new macOS input")

        let reconnection = fixture.headset(id: 80)
        assertEqual(firstConnection.uid, reconnection.uid, "a reconnect keeps its UID but gets a new HAL ID")
        assertEqual(fixture.selection(defaultInput: reconnection).selectedInput, reconnection, "no old device ID is reused")

        MicrophoneChoicePreferences.setChoice(.automatic, userDefaults: fixture.defaults)
        let automatic = fixture.selection(defaultInput: reconnection)
        assertEqual(automatic.selectedInput, fixture.mac, "returning to Automatic skips the current headset")
        assertEqual(automatic.reason, .preferredBuiltInForBluetoothHeadset)
        assertNil(MicrophoneChoicePreferences.choice(userDefaults: fixture.defaults, environment: [:]).deviceUID)

        // A fresh preferences reader uses the same saved choice; no app
        // restart is needed to stop following the headset.
        let reopenedDefaults = UserDefaults(suiteName: fixture.suiteName)!
        assertEqual(MicrophoneChoicePreferences.choice(userDefaults: reopenedDefaults, environment: [:]), .automatic)
        assertEqual(fixture.selection(defaultInput: fixture.headset(id: 90), defaults: reopenedDefaults).selectedInput, fixture.mac)
    }

    runSuite("A persisted speed fallback cannot override Automatic's required headset avoidance") {
        let fixture = MicrophoneChoiceTransitionFixture()
        defer { fixture.cleanUp() }
        MicrophoneChoicePreferences.setChoice(.automatic, userDefaults: fixture.defaults)
        let version = "microphone-transition-fixture"
        let speedPathIsOff: (DictationAudioDevice) -> Bool = { input in
            PinnedDictationSpeedPath.isTurnedOff(for: input, userDefaults: fixture.defaults, appVersion: version)
        }
        let plainMac = fixture.selection(defaultInput: fixture.mac)
        assertTrue(PinnedDictationInputPolicy.recorderIsNeeded(for: plainMac, speedPathIsOff: speedPathIsOff))
        _ = PinnedDictationSpeedPath.record(.empty, for: fixture.mac, userDefaults: fixture.defaults, appVersion: version)
        _ = PinnedDictationSpeedPath.record(.empty, for: fixture.mac, userDefaults: fixture.defaults, appVersion: version)
        assertTrue(speedPathIsOff(fixture.mac), "two empty speed-only takes persist the engine fallback")
        assertFalse(PinnedDictationInputPolicy.recorderIsNeeded(for: plainMac, speedPathIsOff: speedPathIsOff))

        var warmup = PinnedDictationWarmupState()
        warmup.recordEngineFallback()
        assertFalse(warmup.skipsEngineWarmup(for: plainMac, speedPathIsOff: speedPathIsOff), "a safe default can warm the engine after fallback")

        let headset = fixture.headset(id: 80)
        MicrophoneChoicePreferences.setChoice(.macOSInput, userDefaults: fixture.defaults)
        let macOSInput = fixture.selection(defaultInput: headset)
        assertEqual(macOSInput.selectedInput, headset)
        assertFalse(PinnedDictationInputPolicy.recorderIsNeeded(for: macOSInput, speedPathIsOff: speedPathIsOff), "the explicitly selected headset keeps the engine path")
        assertTrue(warmup.skipsEngineWarmup(for: macOSInput, speedPathIsOff: speedPathIsOff), "idle warmup must not open the headset")

        MicrophoneChoicePreferences.setChoice(.automatic, userDefaults: fixture.defaults)
        let automatic = fixture.selection(defaultInput: fixture.headset(id: 90))
        assertEqual(automatic.selectedInput, fixture.mac)
        assertTrue(PinnedDictationInputPolicy.recorderIsRequired(for: automatic))
        assertTrue(PinnedDictationInputPolicy.recorderIsNeeded(for: automatic, speedPathIsOff: speedPathIsOff), "avoiding a headset takes precedence over a persisted speed fallback")
        assertTrue(warmup.skipsEngineWarmup(for: automatic, speedPathIsOff: speedPathIsOff), "a prior setup failure cannot force idle headset warmup")

        warmup.recordRecorderStart()
        assertFalse(warmup.fellBackToEngine, "a successful recorder start clears transient fallback state")
        assertTrue(speedPathIsOff(fixture.mac), "clearing transient fallback does not erase the per-version speed decision")
        assertFalse(PinnedDictationSpeedPath.isTurnedOff(for: fixture.mac, userDefaults: fixture.defaults, appVersion: "next-version"))
    }

    runSuite("Cancelling route recovery leaves the next microphone choice free of stale completion") {
        let fixture = MicrophoneChoiceTransitionFixture()
        defer { fixture.cleanUp() }
        var recovery = ParakeetRecoveryState()
        MicrophoneChoicePreferences.setChoice(.macOSInput, userDefaults: fixture.defaults)
        let oldHeadset = fixture.headset(id: 20)
        assertEqual(fixture.selection(defaultInput: oldHeadset).selectedInput, oldHeadset)
        let cancelledGeneration = recovery.beginConfigChange()
        assertTrue(recovery.cancelRecovery(generation: cancelledGeneration))
        assertFalse(recovery.isRecovering)
        assertTrue(recovery.canStartRecording, "the cancelled recovery cannot strand the next start")

        MicrophoneChoicePreferences.setChoice(.automatic, userDefaults: fixture.defaults)
        recovery.deferUntilNextUse()
        assertFalse(recovery.inputFormatReady, "a new idle route waits for the next start to validate it")
        let nextSelection = fixture.selection(defaultInput: fixture.headset(id: 80))
        assertTrue(PinnedDictationInputPolicy.skipsEngineWarmup(for: nextSelection, afterEngineFallback: false))
        recovery.markFormatReady()
        assertEqual(nextSelection.selectedInput, fixture.mac)
        assertFalse(recovery.finishRecovery(success: false, generation: cancelledGeneration), "a late failure cannot overwrite readiness for the new choice")
        assertFalse(recovery.timeoutRecovery(generation: cancelledGeneration), "a late timeout also belongs to the cancelled route")
        assertTrue(recovery.canStartRecording)
    }
}

/// CoreAudio inventories are supplied as values. These tests open no device,
/// instantiate no audio engine, and use only a disposable preferences suite.
private struct MicrophoneChoiceTransitionFixture {
    let suiteName: String
    let defaults: UserDefaults
    let mac = DictationAudioDevice(id: 1, name: "Built-In Microphone", transport: .builtIn, inputChannelCount: 1, uid: "fixture-mac")

    init() {
        suiteName = "MicrophoneChoiceTransitionsTests.\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suiteName)!
        PinnedMicrophoneCapturePreferences.setEnabled(true, userDefaults: defaults)
    }

    func cleanUp() {
        defaults.removePersistentDomain(forName: suiteName)
    }

    func headset(id: UInt32) -> DictationAudioDevice {
        DictationAudioDevice(id: id, name: "Bluetooth Headset", transport: .bluetooth, inputChannelCount: 1, uid: "fixture-headset")
    }

    func selection(defaultInput: DictationAudioDevice, defaults: UserDefaults? = nil) -> DictationInputDeviceSelection {
        let choice = MicrophoneChoicePreferences.choice(userDefaults: defaults ?? self.defaults, environment: [:])
        let inputs = defaultInput.id == mac.id ? [mac] : [mac, defaultInput]
        // Neither fixture closure throws: force-try keeps a failure visible
        // instead of silently substituting a successful-looking selection.
        return try! PinnedDictationInputPolicy.pinnedSelection(
            followsMacOSInput: choice == .macOSInput,
            chosenUID: choice.deviceUID,
            lidClosed: false,
            excludingDeviceID: nil,
            automaticSelection: { prefersBuiltIn in
                DictationInputDeviceSelectionPolicy.selection(
                    defaultInput: defaultInput,
                    defaultOutput: defaultInput,
                    availableInputs: inputs,
                    prefersBuiltInBluetoothInput: prefersBuiltIn
                )
            },
            availableInputs: { inputs }
        )
    }
}
