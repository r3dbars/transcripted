import Foundation

// A wired headset's name often says "Headset", but Core Audio already tells us
// its transport. Only an unknown or Bluetooth transport falls back to the name.
func testDictationWiredHeadsetClass() {
    runSuite("A USB or built-in headset is a wired mic, not Bluetooth, whatever its name") {
        let usbHeadset = DictationAudioDevice(id: 1, name: "Logitech USB Headset", transport: .usb, inputChannelCount: 1, uid: "usb-headset")
        let jabra = DictationAudioDevice(id: 2, name: "Jabra Evolve2 30 Headset", transport: .usb, inputChannelCount: 1, uid: "jabra")
        let jackHeadset = DictationAudioDevice(id: 3, name: "External Headset Microphone", transport: .builtIn, inputChannelCount: 1, uid: "jack")

        assertEqual(DictationInputDeviceSelectionPolicy.deviceClass(for: usbHeadset), "external", "a USB headset is a wired mic")
        assertEqual(DictationInputDeviceSelectionPolicy.deviceClass(for: jabra), "external", "a USB Jabra headset is a wired mic")
        assertEqual(DictationInputDeviceSelectionPolicy.deviceClass(for: jackHeadset), "built_in", "a headphone-jack headset is built in")
    }

    runSuite("A chosen USB headset mic is kept, and as the macOS input it isn't steered away") {
        let usbHeadset = DictationAudioDevice(id: 1, name: "Logitech USB Headset", transport: .usb, inputChannelCount: 1, uid: "usb-headset")
        let usbOutput = DictationAudioDevice(id: 2, name: "Logitech USB Headset", transport: .usb, inputChannelCount: 0, uid: "usb-headset-out")
        let macMic = DictationAudioDevice(id: 3, name: "MacBook Pro Microphone", transport: .builtIn, inputChannelCount: 1, uid: "mac")

        assertEqual(
            DictationPreferredInputPolicy.input(preferredUID: "usb-headset", availableInputs: [usbHeadset, macMic], automaticFallback: macMic),
            usbHeadset,
            "a USB headset picked as the preferred mic should be used"
        )

        let selection = DictationInputDeviceSelectionPolicy.selection(
            defaultInput: usbHeadset,
            defaultOutput: usbOutput,
            availableInputs: [usbHeadset, macMic],
            prefersBuiltInBluetoothInput: true
        )
        assertEqual(selection.selectedInput, usbHeadset, "a USB headset as the macOS input should be recorded, not swapped for the Mac mic")
        assertEqual(selection.reason, .defaultIsSafe, "a USB headset is a safe input")
    }

    runSuite("Bluetooth headsets are still excluded by transport or, when unknown, by name") {
        let airPods = DictationAudioDevice(id: 1, name: "Justin's AirPods Pro", transport: .bluetooth, inputChannelCount: 1, uid: "airpods")
        let leHeadset = DictationAudioDevice(id: 2, name: "Studio Mic", transport: .bluetoothLE, inputChannelCount: 1, uid: "le")
        let unknownHeadset = DictationAudioDevice(id: 3, name: "Bose Headset", transport: .other, inputChannelCount: 1, uid: "unknown")
        let macMic = DictationAudioDevice(id: 4, name: "MacBook Pro Microphone", transport: .builtIn, inputChannelCount: 1, uid: "mac")

        assertEqual(DictationInputDeviceSelectionPolicy.deviceClass(for: airPods), "bluetooth", "AirPods stay Bluetooth")
        assertEqual(DictationInputDeviceSelectionPolicy.deviceClass(for: leHeadset), "bluetooth", "a Bluetooth LE transport is Bluetooth whatever its name")
        assertEqual(DictationInputDeviceSelectionPolicy.deviceClass(for: unknownHeadset), "bluetooth", "an unknown transport still uses the headset name")
        assertEqual(DictationInputDeviceSelectionPolicy.deviceClass(forName: "AirPods Max"), "bluetooth", "a bare AirPods name is Bluetooth")

        for headset in [airPods, unknownHeadset] {
            assertEqual(
                DictationPreferredInputPolicy.input(preferredUID: headset.uid, availableInputs: [headset, macMic], automaticFallback: macMic),
                macMic,
                "a Bluetooth headset is never used as the preferred mic"
            )
            let selection = DictationInputDeviceSelectionPolicy.selection(
                defaultInput: headset,
                defaultOutput: headset,
                availableInputs: [headset, macMic],
                prefersBuiltInBluetoothInput: true
            )
            assertEqual(selection.selectedInput, macMic, "a Bluetooth headset as the macOS input is still steered to the Mac mic")
        }
    }
}
