import CoreAudio
import XCTest
@testable import TranscriptedCore

final class MeetingInputDeviceSelectionPolicyTests: XCTestCase {
    func testOverriddenBuiltInRouteRejectsStaleBluetoothSampleRate() {
        let bluetoothMic = device(id: 10, name: "Bluetooth Headset", transport: .bluetooth, channels: 1)
        let builtInMic = device(id: 20, name: "MacBook Pro Microphone", transport: .builtIn, channels: 1)
        let selection = MeetingInputDeviceSelection(
            defaultInput: bluetoothMic,
            selectedInput: builtInMic,
            defaultOutput: bluetoothMic,
            reason: .preferredBuiltInForBluetoothHeadset
        )

        XCTAssertEqual(
            MeetingInputDeviceSelectionPolicy.routeReadiness(
                selection: selection,
                boundInputDeviceIDBeforeVoiceProcessing: builtInMic.id,
                actualInputDeviceID: builtInMic.id,
                capturedSampleRate: 24_000,
                selectedNominalSampleRate: 48_000,
                voiceProcessingEnabled: false
            ),
            .sampleRateMismatch
        )
        XCTAssertEqual(
            MeetingInputDeviceSelectionPolicy.routeReadiness(
                selection: selection,
                boundInputDeviceIDBeforeVoiceProcessing: builtInMic.id,
                actualInputDeviceID: builtInMic.id,
                capturedSampleRate: 48_000,
                selectedNominalSampleRate: 48_000,
                voiceProcessingEnabled: false
            ),
            .ready
        )
    }

    func testVoiceProcessingAcceptsPrivatePostWrapIdentityOnlyAfterSelectedMicWasBound() {
        let bluetoothMic = device(id: 10, name: "Bluetooth Headset", transport: .bluetooth, channels: 1)
        let builtInMic = device(id: 20, name: "MacBook Pro Microphone", transport: .builtIn, channels: 1)
        let selection = MeetingInputDeviceSelection(
            defaultInput: bluetoothMic,
            selectedInput: builtInMic,
            defaultOutput: bluetoothMic,
            reason: .preferredBuiltInForBluetoothHeadset
        )

        XCTAssertEqual(
            MeetingInputDeviceSelectionPolicy.routeReadiness(
                selection: selection,
                boundInputDeviceIDBeforeVoiceProcessing: builtInMic.id,
                // VPIO can expose an unknown or private device ID after it
                // wraps the already-bound physical microphone.
                actualInputDeviceID: 0,
                capturedSampleRate: 24_000,
                selectedNominalSampleRate: 48_000,
                voiceProcessingEnabled: true
            ),
            .ready
        )
        XCTAssertEqual(
            MeetingInputDeviceSelectionPolicy.routeReadiness(
                selection: selection,
                boundInputDeviceIDBeforeVoiceProcessing: builtInMic.id,
                actualInputDeviceID: 999,
                capturedSampleRate: 24_000,
                selectedNominalSampleRate: 48_000,
                voiceProcessingEnabled: true
            ),
            .ready
        )
        XCTAssertEqual(
            MeetingInputDeviceSelectionPolicy.routeReadiness(
                selection: selection,
                boundInputDeviceIDBeforeVoiceProcessing: bluetoothMic.id,
                actualInputDeviceID: 999,
                capturedSampleRate: 24_000,
                selectedNominalSampleRate: 48_000,
                voiceProcessingEnabled: true
            ),
            .deviceMismatch,
            "VPIO must not hide a wrong physical microphone before wrapping"
        )
        XCTAssertEqual(
            MeetingInputDeviceSelectionPolicy.routeReadiness(
                selection: selection,
                boundInputDeviceIDBeforeVoiceProcessing: builtInMic.id,
                actualInputDeviceID: 999,
                capturedSampleRate: 48_000,
                selectedNominalSampleRate: 48_000,
                voiceProcessingEnabled: false
            ),
            .deviceMismatch,
            "the raw path must keep reporting the exact selected microphone"
        )
    }

    func testFailedStartTimeSwitchDoesNotPersistUnappliedBuiltInSelection() {
        let bluetoothMic = device(id: 10, name: "Bluetooth Headset", transport: .bluetooth, channels: 1)
        let builtInMic = device(id: 20, name: "MacBook Pro Microphone", transport: .builtIn, channels: 1)
        let attemptedSelection = MeetingInputDeviceSelection(
            defaultInput: bluetoothMic,
            selectedInput: builtInMic,
            defaultOutput: bluetoothMic,
            reason: .preferredBuiltInForBluetoothHeadset
        )

        XCTAssertNil(
            MeetingInputDeviceSelectionPolicy.selectionAfterApplicationAttempt(
                currentSelection: nil,
                attemptedSelection: attemptedSelection,
                didApplySelection: false
            ),
            "a rejected CoreAudio switch must not claim that built-in input is pinned"
        )
        XCTAssertTrue(
            MeetingInputDeviceSelectionPolicy.shouldAbortMeetingStart(after: .switchFailed),
            "meeting capture must not continue on the Bluetooth mic after the safety switch fails"
        )
        XCTAssertEqual(
            MeetingInputDeviceSelectionPolicy.outcomeAfterApplicationFailure(
                selectionReason: .preferredBuiltInForBluetoothHeadset,
                requestedOutcome: .notNeeded
            ),
            .switchFailed
        )
        XCTAssertFalse(
            MeetingInputDeviceSelectionPolicy.shouldAbortMeetingStart(after: .notNeeded)
        )
    }

    func testFailedSafeInputSyncDoesNotPersistOrAbort() {
        let usbMic = device(id: 10, name: "USB Microphone", transport: .usb, channels: 2)
        let attemptedSelection = MeetingInputDeviceSelection(
            defaultInput: usbMic,
            selectedInput: usbMic,
            defaultOutput: nil,
            reason: .defaultIsSafe
        )

        XCTAssertNil(
            MeetingInputDeviceSelectionPolicy.selectionAfterApplicationAttempt(
                currentSelection: nil,
                attemptedSelection: attemptedSelection,
                didApplySelection: false
            ),
            "a rejected safe-input sync must not persist a route that was never applied"
        )
        XCTAssertFalse(
            MeetingInputDeviceSelectionPolicy.shouldAbortMeetingStart(after: .notNeeded),
            "safe built-in and USB sync failures retain the existing nonfatal start behavior"
        )
        XCTAssertEqual(
            MeetingInputDeviceSelectionPolicy.outcomeAfterApplicationFailure(
                selectionReason: .defaultIsSafe,
                requestedOutcome: .notNeeded
            ),
            .notNeeded
        )
    }

    func testFailedExplicitInputBindAbortsBeforeAnUnselectedRouteCanBecomeReady() {
        let bluetoothMic = device(id: 10, name: "AirPods Pro", transport: .bluetooth, channels: 1)
        let usbMic = device(id: 20, name: "USB Microphone", transport: .usb, channels: 1)
        let builtInMic = device(id: 30, name: "MacBook Pro Microphone", transport: .builtIn, channels: 1)

        for selectedMic in [bluetoothMic, usbMic, builtInMic] {
            let attemptedSelection = MeetingInputDeviceSelectionPolicy.selectionForMeetingStart(
                defaultInput: selectedMic,
                defaultOutput: bluetoothMic,
                availableInputs: [bluetoothMic, usbMic, builtInMic],
                mode: .preserveDefault
            )
            XCTAssertEqual(attemptedSelection.reason, .preservedDefaultInput)
            XCTAssertNil(MeetingInputDeviceSelectionPolicy.selectionAfterApplicationAttempt(
                currentSelection: nil,
                attemptedSelection: attemptedSelection,
                didApplySelection: false
            ))

            let outcome = MeetingInputDeviceSelectionPolicy.outcomeAfterApplicationFailure(
                selectionReason: attemptedSelection.reason,
                requestedOutcome: .notNeeded
            )
            XCTAssertEqual(outcome, .switchFailed)
            XCTAssertTrue(
                MeetingInputDeviceSelectionPolicy.shouldAbortMeetingStart(after: outcome),
                "a failed explicit bind must not reach routeReadiness with nil selection and use the previous mic"
            )
        }
    }

    func testExplicitInputLookupFailureCannotProceedWithAnUnknownMicrophone() {
        let explicitOutcome = MeetingInputDeviceSelectionPolicy.outcomeAfterLookupFailure(
            mode: .preserveDefault
        )
        XCTAssertEqual(explicitOutcome, .switchFailed)
        XCTAssertTrue(MeetingInputDeviceSelectionPolicy.shouldAbortMeetingStart(after: explicitOutcome))

        let automaticOutcome = MeetingInputDeviceSelectionPolicy.outcomeAfterLookupFailure(
            mode: .automatic
        )
        XCTAssertEqual(automaticOutcome, .notNeeded)
        XCTAssertFalse(MeetingInputDeviceSelectionPolicy.shouldAbortMeetingStart(after: automaticOutcome))
    }

    func testMeetingStartAvoidsSharingBluetoothHeadsetMicWithCallApps() {
        let bluetoothMic = device(
            id: 10,
            name: "Bluetooth Headset Microphone",
            transport: .bluetooth,
            channels: 1
        )
        let macBookMic = device(
            id: 20,
            name: "MacBook Pro Microphone",
            transport: .builtIn,
            channels: 1
        )

        let selection = MeetingInputDeviceSelectionPolicy.selectionForMeetingStart(
            defaultInput: bluetoothMic,
            defaultOutput: bluetoothMic,
            availableInputs: [bluetoothMic, macBookMic]
        )

        XCTAssertEqual(selection.selectedInput, macBookMic)
        XCTAssertEqual(selection.reason, .preferredBuiltInForBluetoothHeadset)
        XCTAssertTrue(selection.didOverrideDefault)
    }

    func testMeetingStartHonorsExplicitMacOSMicrophoneMode() {
        let bluetoothMic = device(id: 10, name: "AirPods Pro", transport: .bluetooth, channels: 1)
        let builtInMic = device(id: 20, name: "MacBook Pro Microphone", transport: .builtIn, channels: 1)

        for output in [bluetoothMic, nil] as [MeetingAudioDevice?] {
            let selection = MeetingInputDeviceSelectionPolicy.selectionForMeetingStart(
                defaultInput: bluetoothMic,
                defaultOutput: output,
                availableInputs: [bluetoothMic, builtInMic],
                mode: .preserveDefault
            )

            XCTAssertEqual(selection.selectedInput, bluetoothMic)
            XCTAssertEqual(selection.reason, .preservedDefaultInput)
            XCTAssertFalse(selection.didOverrideDefault)
        }
    }

    func testExplicitMacOSMicrophoneModeRetainsBoundedFailureFallback() {
        let bluetoothMic = device(id: 10, name: "AirPods Pro", transport: .bluetooth, channels: 1)
        let builtInMic = device(id: 20, name: "MacBook Pro Microphone", transport: .builtIn, channels: 1)
        let selection = MeetingInputDeviceSelectionPolicy.selectionForMeetingStart(
            defaultInput: bluetoothMic,
            defaultOutput: bluetoothMic,
            availableInputs: [bluetoothMic, builtInMic],
            mode: .preserveDefault
        )

        XCTAssertFalse(MeetingInputDeviceSelectionPolicy.shouldAttemptBuiltInStabilization(
            routeWasUnstable: false,
            selectedInput: selection.selectedInput,
            stabilizationAlreadyAttempted: false
        ), "an intentional Bluetooth input must not switch just because capture starts or processing restarts")
        XCTAssertTrue(MeetingInputDeviceSelectionPolicy.shouldAttemptBuiltInStabilization(
            routeWasUnstable: true,
            selectedInput: selection.selectedInput,
            stabilizationAlreadyAttempted: false
        ), "preserving the macOS input must not disable recovery after a real route failure")
        XCTAssertFalse(MeetingInputDeviceSelectionPolicy.shouldAttemptBuiltInStabilization(
            routeWasUnstable: true,
            selectedInput: selection.selectedInput,
            stabilizationAlreadyAttempted: true
        ), "the existing stabilization attempt stays bounded")
        XCTAssertFalse(MeetingInputDeviceSelectionPolicy.shouldAttemptBuiltInStabilization(
            routeWasUnstable: true,
            selectedInput: builtInMic,
            stabilizationAlreadyAttempted: false
        ))
    }

    func testFailedBuiltInStabilizationRestoresPinnedBluetoothSelection() {
        let bluetoothMic = device(id: 10, name: "Bluetooth Headset", transport: .bluetooth, channels: 1)
        let builtInMic = device(id: 20, name: "MacBook Pro Microphone", transport: .builtIn, channels: 1)
        let pinnedSelection = MeetingInputDeviceSelection(
            defaultInput: bluetoothMic,
            selectedInput: bluetoothMic,
            defaultOutput: bluetoothMic,
            reason: .preservedDefaultInput
        )
        let fallbackSelection = MeetingInputDeviceSelection(
            defaultInput: bluetoothMic,
            selectedInput: builtInMic,
            defaultOutput: bluetoothMic,
            reason: .preferredBuiltInForBluetoothHeadset
        )

        XCTAssertEqual(
            MeetingInputDeviceSelectionPolicy.selectionAfterStabilizationAttempt(
                pinnedSelection: pinnedSelection,
                attemptedSelection: fallbackSelection,
                outcome: .switchFailed
            ),
            pinnedSelection,
            "a failed built-in setDeviceID must leave the original Bluetooth input pinned"
        )
        XCTAssertEqual(
            MeetingInputDeviceSelectionPolicy.selectionAfterStabilizationAttempt(
                pinnedSelection: pinnedSelection,
                attemptedSelection: fallbackSelection,
                outcome: .switchedToBuiltIn
            ),
            fallbackSelection,
            "only a successful built-in application may replace the pinned selection"
        )
    }

    func testPreserveDefaultModeDoesNotOverrideAnIntentionalBluetoothMic() {
        let bluetoothMic = device(
            id: 10,
            name: "Bluetooth Headset Microphone",
            transport: .bluetooth,
            channels: 1
        )
        let macBookMic = device(
            id: 20,
            name: "MacBook Pro Microphone",
            transport: .builtIn,
            channels: 1
        )

        let selection = MeetingInputDeviceSelectionPolicy.selection(
            defaultInput: bluetoothMic,
            defaultOutput: bluetoothMic,
            availableInputs: [bluetoothMic, macBookMic],
            mode: .preserveDefault
        )

        XCTAssertEqual(selection.selectedInput, bluetoothMic)
        XCTAssertEqual(selection.reason, .preservedDefaultInput)
        XCTAssertFalse(selection.didOverrideDefault)
    }

    func testBuiltInFallbackIsOnlyAvailableForBluetoothInputs() {
        let bluetoothMic = device(id: 10, name: "Bluetooth Headset", transport: .bluetooth, channels: 1)
        let macBookMic = device(id: 20, name: "MacBook Pro Microphone", transport: .builtIn, channels: 1)
        let aggregateMic = device(id: 30, name: "Aggregate Input", transport: .aggregate, channels: 2)

        XCTAssertEqual(
            MeetingInputDeviceSelectionPolicy.preferredBuiltInFallback(
                for: bluetoothMic,
                availableInputs: [bluetoothMic, macBookMic, aggregateMic]
            ),
            macBookMic
        )
        XCTAssertNil(
            MeetingInputDeviceSelectionPolicy.preferredBuiltInFallback(
                for: aggregateMic,
                availableInputs: [aggregateMic, macBookMic]
            )
        )
    }

    func testPrefersBuiltInInputWhenDefaultInputAndOutputAreBluetooth() {
        let airPods = device(
            id: 10,
            name: "Justin's AirPods Pro",
            transport: .bluetooth,
            channels: 1
        )
        let macBookMic = device(
            id: 20,
            name: "MacBook Pro Microphone",
            transport: .builtIn,
            channels: 1
        )

        let selection = MeetingInputDeviceSelectionPolicy.selection(
            defaultInput: airPods,
            defaultOutput: airPods,
            availableInputs: [airPods, macBookMic]
        )

        XCTAssertEqual(selection.selectedInput, macBookMic)
        XCTAssertEqual(selection.reason, .preferredBuiltInForBluetoothHeadset)
        XCTAssertTrue(selection.didOverrideDefault)
    }

    func testKeepsDefaultInputWhenOutputIsNotBluetooth() {
        let usbMic = device(id: 10, name: "Scarlett Microphone", transport: .usb, channels: 2)
        let headphones = device(id: 20, name: "External Headphones", transport: .usb, channels: 0)
        let macBookMic = device(id: 30, name: "MacBook Pro Microphone", transport: .builtIn, channels: 1)

        let selection = MeetingInputDeviceSelectionPolicy.selection(
            defaultInput: usbMic,
            defaultOutput: headphones,
            availableInputs: [usbMic, macBookMic]
        )

        XCTAssertEqual(selection.selectedInput, usbMic)
        XCTAssertEqual(selection.reason, .defaultIsSafe)
        XCTAssertFalse(selection.didOverrideDefault)
    }

    func testKeepsBluetoothInputWhenNoBuiltInFallbackExists() {
        let airPods = device(id: 10, name: "AirPods Pro", transport: .bluetooth, channels: 1)

        let selection = MeetingInputDeviceSelectionPolicy.selection(
            defaultInput: airPods,
            defaultOutput: airPods,
            availableInputs: [airPods]
        )

        XCTAssertEqual(selection.selectedInput, airPods)
        XCTAssertEqual(selection.reason, .noBuiltInFallbackAvailable)
        XCTAssertFalse(selection.didOverrideDefault)
    }

    func testPrefersBuiltInInputWhenBluetoothOutputLookupIsUnavailable() {
        let airPods = device(id: 10, name: "AirPods Pro", transport: .bluetooth, channels: 1)
        let macBookMic = device(id: 20, name: "MacBook Pro Microphone", transport: .builtIn, channels: 1)

        let selection = MeetingInputDeviceSelectionPolicy.selection(
            defaultInput: airPods,
            defaultOutput: nil,
            availableInputs: [airPods, macBookMic]
        )

        XCTAssertEqual(selection.selectedInput, macBookMic)
        XCTAssertEqual(selection.reason, .preferredBuiltInForBluetoothHeadset)
        XCTAssertTrue(selection.didOverrideDefault)
    }

    func testRanksMacBookMicrophoneAheadOfOtherBuiltInCandidates() {
        let airPods = device(id: 10, name: "AirPods Pro", transport: .bluetooth, channels: 1)
        let studioDisplayMic = device(
            id: 20,
            name: "Studio Display Microphone",
            transport: .builtIn,
            channels: 1
        )
        let macBookMic = device(
            id: 30,
            name: "MacBook Pro Microphone",
            transport: .builtIn,
            channels: 1
        )

        let selection = MeetingInputDeviceSelectionPolicy.selection(
            defaultInput: airPods,
            defaultOutput: airPods,
            availableInputs: [studioDisplayMic, macBookMic, airPods]
        )

        XCTAssertEqual(selection.selectedInput, macBookMic)
    }

    func testClosedLidSkipsTheMacBookMicForTheStudioDisplayMic() {
        let airPods = device(id: 10, name: "AirPods Pro", transport: .bluetooth, channels: 1)
        let studioDisplayMic = device(id: 20, name: "Studio Display Microphone", transport: .usb, channels: 1)
        let macBookMic = device(id: 30, name: "MacBook Pro Microphone", transport: .builtIn, channels: 1)

        let selection = MeetingInputDeviceSelectionPolicy.selection(
            defaultInput: airPods,
            defaultOutput: airPods,
            availableInputs: [studioDisplayMic, macBookMic, airPods],
            lidClosed: true
        )

        XCTAssertEqual(selection.selectedInput, studioDisplayMic)
        XCTAssertEqual(selection.reason, .preferredBuiltInForBluetoothHeadset)
    }

    func testClosedLidWithOnlyTheMacBookMicKeepsTheHeadset() {
        let airPods = device(id: 10, name: "AirPods Pro", transport: .bluetooth, channels: 1)
        let macBookMic = device(id: 30, name: "MacBook Air Microphone", transport: .builtIn, channels: 1)
        let jackMic = device(id: 40, name: "External Microphone", transport: .builtIn, channels: 1)

        let deadOnly = MeetingInputDeviceSelectionPolicy.selection(
            defaultInput: airPods,
            defaultOutput: airPods,
            availableInputs: [macBookMic, airPods],
            lidClosed: true
        )
        XCTAssertEqual(deadOnly.selectedInput, airPods, "a closed lid's mic hears nothing")
        XCTAssertEqual(deadOnly.reason, .noBuiltInFallbackAvailable)

        let withJack = MeetingInputDeviceSelectionPolicy.selection(
            defaultInput: airPods,
            defaultOutput: airPods,
            availableInputs: [macBookMic, jackMic, airPods],
            lidClosed: true
        )
        XCTAssertEqual(withJack.selectedInput, jackMic, "the headphone-jack mic works with the lid closed")
        XCTAssertFalse(MeetingInputDeviceSelectionPolicy.isLidMicrophone(jackMic))
        XCTAssertTrue(MeetingInputDeviceSelectionPolicy.isLidMicrophone(macBookMic))
    }

    func testPinnedRecorderIsOnlyNeededToSkipABluetoothDefaultInput() {
        let airPods = device(id: 10, name: "AirPods Pro", transport: .bluetooth, channels: 1)
        let macBookMic = device(id: 30, name: "MacBook Pro Microphone", transport: .builtIn, channels: 1)
        let usbMic = device(id: 40, name: "Yeti", transport: .usb, channels: 1)

        let skipsHeadset = MeetingInputDeviceSelectionPolicy.selection(
            defaultInput: airPods,
            defaultOutput: airPods,
            availableInputs: [airPods, macBookMic]
        )
        XCTAssertTrue(MeetingInputDeviceSelectionPolicy.pinnedRecorderIsNeeded(for: skipsHeadset))

        let headsetOnly = MeetingInputDeviceSelectionPolicy.selection(
            defaultInput: airPods,
            defaultOutput: airPods,
            availableInputs: [airPods]
        )
        XCTAssertFalse(MeetingInputDeviceSelectionPolicy.pinnedRecorderIsNeeded(for: headsetOnly))

        let usbDefault = MeetingInputDeviceSelectionPolicy.selection(
            defaultInput: usbMic,
            defaultOutput: airPods,
            availableInputs: [airPods, macBookMic, usbMic]
        )
        XCTAssertFalse(MeetingInputDeviceSelectionPolicy.pinnedRecorderIsNeeded(for: usbDefault))
    }

    func testChosenMicIsRecordedOverTheMacOSInput() {
        let airPods = device(id: 10, name: "AirPods Pro", transport: .bluetooth, channels: 1)
        let macBookMic = device(id: 20, name: "MacBook Pro Microphone", transport: .builtIn, channels: 1)
        let usbMic = device(id: 30, name: "Shure MV7", transport: .usb, channels: 1)
        let inputs = [airPods, macBookMic, usbMic]

        let overSafeDefault = MeetingInputDeviceSelectionPolicy.selection(
            defaultInput: macBookMic,
            defaultOutput: nil,
            availableInputs: inputs,
            preferredInputID: usbMic.id
        )
        XCTAssertEqual(overSafeDefault.selectedInput, usbMic)
        XCTAssertEqual(overSafeDefault.reason, .userChosenInput)
        XCTAssertFalse(
            MeetingInputDeviceSelectionPolicy.pinnedRecorderIsNeeded(for: overSafeDefault),
            "the engine can move off a non-headset default without touching AirPods"
        )

        let overHeadset = MeetingInputDeviceSelectionPolicy.selection(
            defaultInput: airPods,
            defaultOutput: airPods,
            availableInputs: inputs,
            preferredInputID: usbMic.id
        )
        XCTAssertEqual(overHeadset.selectedInput, usbMic, "the chosen mic beats the built-in pick too")
        XCTAssertEqual(overHeadset.reason, .userChosenInput)
        XCTAssertTrue(MeetingInputDeviceSelectionPolicy.pinnedRecorderIsNeeded(for: overHeadset))

        let preserved = MeetingInputDeviceSelectionPolicy.selection(
            defaultInput: airPods,
            defaultOutput: airPods,
            availableInputs: inputs,
            mode: .preserveDefault,
            preferredInputID: usbMic.id
        )
        XCTAssertEqual(preserved.reason, .preservedDefaultInput, "keeping the macOS input on purpose wins")
    }

    func testChosenMicNeverPicksAHeadsetOrAClosedLidMic() {
        let airPods = device(id: 10, name: "AirPods Pro", transport: .bluetooth, channels: 1)
        let macBookMic = device(id: 20, name: "MacBook Pro Microphone", transport: .builtIn, channels: 1)
        let usbMic = device(id: 30, name: "Shure MV7", transport: .usb, channels: 1)
        let inputs = [airPods, macBookMic, usbMic]

        let headsetChosen = MeetingInputDeviceSelectionPolicy.selection(
            defaultInput: usbMic,
            defaultOutput: airPods,
            availableInputs: inputs,
            preferredInputID: airPods.id
        )
        XCTAssertEqual(headsetChosen.selectedInput, usbMic, "a saved headset pick never puts it into call mode")
        XCTAssertEqual(headsetChosen.reason, .defaultIsSafe)

        let lidMicChosen = MeetingInputDeviceSelectionPolicy.selection(
            defaultInput: airPods,
            defaultOutput: airPods,
            availableInputs: inputs,
            preferredInputID: macBookMic.id,
            lidClosed: true
        )
        XCTAssertNotEqual(lidMicChosen.selectedInput, macBookMic, "a closed MacBook's mic records silence")
        XCTAssertNotEqual(lidMicChosen.reason, .userChosenInput)

        let unplugged = MeetingInputDeviceSelectionPolicy.selection(
            defaultInput: airPods,
            defaultOutput: airPods,
            availableInputs: [airPods, macBookMic],
            preferredInputID: usbMic.id
        )
        XCTAssertEqual(unplugged.selectedInput, macBookMic, "a missing pick falls back to the automatic choice")
        XCTAssertEqual(unplugged.reason, .preferredBuiltInForBluetoothHeadset)

        let chosenIsDefault = MeetingInputDeviceSelectionPolicy.selection(
            defaultInput: usbMic,
            defaultOutput: nil,
            availableInputs: inputs,
            preferredInputID: usbMic.id
        )
        XCTAssertEqual(chosenIsDefault.reason, .defaultIsSafe, "nothing to override")
    }

    func testUnappliedChosenMicFailsTheAttemptInsteadOfRecordingAnotherMic() {
        XCTAssertEqual(
            MeetingInputDeviceSelectionPolicy.outcomeAfterApplicationFailure(
                selectionReason: .userChosenInput,
                requestedOutcome: .notNeeded
            ),
            .switchFailed
        )
    }

    private func device(
        id: AudioDeviceID,
        name: String,
        transport: MeetingAudioTransport,
        channels: UInt32
    ) -> MeetingAudioDevice {
        MeetingAudioDevice(
            id: id,
            name: name,
            transport: transport,
            inputChannelCount: channels
        )
    }
}
