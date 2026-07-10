import AVFoundation
import Foundation

func testParakeetPrewarmPolicy() {
    runSuite("ParakeetPrewarmPolicy — defers invasive Bluetooth fallback prewarm") {
        let bluetoothInput = DictationAudioDevice(
            id: 10,
            name: "Bluetooth Headset",
            transport: .bluetooth,
            inputChannelCount: 1
        )
        let builtInInput = DictationAudioDevice(
            id: 20,
            name: "MacBook Pro Microphone",
            transport: .builtIn,
            inputChannelCount: 1
        )
        let bluetoothOutput = DictationAudioDevice(
            id: 30,
            name: "Bluetooth Headset",
            transport: .bluetooth,
            inputChannelCount: 0
        )
        let fallbackSelection = DictationInputDeviceSelection(
            defaultInput: bluetoothInput,
            selectedInput: builtInInput,
            defaultOutput: bluetoothOutput,
            reason: .preferredBuiltInForBluetoothHeadset
        )

        assertTrue(
            ParakeetPrewarmPolicy.shouldDeferHardwarePrewarm(for: fallbackSelection),
            "idle prewarm should not repeatedly change the Mac-wide input for Bluetooth fallback"
        )
        assertTrue(
            ParakeetPrewarmPolicy.shouldDeferHardwareRecovery(
                for: fallbackSelection,
                wasRecording: false
            ),
            "idle route recovery after stop should not reapply the Bluetooth fallback override"
        )
        assertFalse(
            ParakeetPrewarmPolicy.shouldDeferHardwareRecovery(
                for: fallbackSelection,
                wasRecording: true
            ),
            "an interrupted recording should still recover its real microphone graph"
        )
        assertFalse(
            ParakeetPrewarmPolicy.shouldDeferHardwarePrewarm(
                for: DictationInputDeviceSelection(
                    defaultInput: builtInInput,
                    selectedInput: builtInInput,
                    defaultOutput: bluetoothOutput,
                    reason: .defaultIsSafe
                )
            ),
            "safe native routes should keep normal hardware prewarm"
        )
        assertFalse(
            ParakeetPrewarmPolicy.shouldDeferHardwarePrewarm(for: nil),
            "missing route metadata should keep normal prewarm behavior"
        )
    }

    runSuite("ParakeetPrewarmPolicy.decision — authorized microphone can prewarm") {
        let decision = ParakeetPrewarmPolicy.decision(for: .authorized)

        assertEqual(decision, .proceed, "authorized microphone access should allow prewarm")
    }

    runSuite("ParakeetPrewarmPolicy.decision — pending permission skips prewarm without an error") {
        let decision = ParakeetPrewarmPolicy.decision(for: .notDetermined)

        assertEqual(
            decision,
            .skip(
                level: .info,
                event: "prewarm_permission_pending",
                message: "Skipping speech engine prewarm until microphone permission is decided",
                context: ["mic_status": "not_determined"]
            ),
            "pending permission should defer prewarm until the user answers the prompt"
        )
    }

    runSuite("ParakeetPrewarmPolicy.decision — denied permission skips prewarm with a warning") {
        let decision = ParakeetPrewarmPolicy.decision(for: .denied)

        assertEqual(
            decision,
            .skip(
                level: .warning,
                event: "prewarm_permission_unavailable",
                message: "Skipping speech engine prewarm because microphone permission is unavailable",
                context: ["mic_status": "denied"]
            ),
            "missing microphone access should stop prewarm from surfacing as a startup failure"
        )
    }

    runSuite("ParakeetPrewarmPolicy.decision — restricted permission reports the concrete status") {
        let decision = ParakeetPrewarmPolicy.decision(for: .restricted)

        assertEqual(
            decision,
            .skip(
                level: .warning,
                event: "prewarm_permission_unavailable",
                message: "Skipping speech engine prewarm because microphone permission is unavailable",
                context: ["mic_status": "restricted"]
            ),
            "restricted microphone access should be warning-level but privacy-safe"
        )
    }
}
