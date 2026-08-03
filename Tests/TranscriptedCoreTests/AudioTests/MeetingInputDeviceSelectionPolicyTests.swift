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
