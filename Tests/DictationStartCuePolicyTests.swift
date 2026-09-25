import Foundation

func testDictationStartCuePolicy() {
    runSuite("Start click plays on key press for a built-in or wired mic") {
        let builtIn = DictationAudioDevice(id: 1, name: "MacBook Pro Microphone", transport: .builtIn, inputChannelCount: 1)
        let usb = DictationAudioDevice(id: 2, name: "Shure MV7", transport: .usb, inputChannelCount: 1)
        assertTrue(DictationStartCuePolicy.playsOnKeyPress(recordedInput: builtIn), "built-in mic")
        assertTrue(DictationStartCuePolicy.playsOnKeyPress(recordedInput: usb), "USB mic")
    }

    runSuite("Start click waits for recording on inputs that could be a headset") {
        let airPods = DictationAudioDevice(id: 3, name: "AirPods Pro", transport: .bluetooth, inputChannelCount: 1)
        let bluetoothLE = DictationAudioDevice(id: 4, name: "Headset", transport: .bluetoothLE, inputChannelCount: 1)
        let aggregate = DictationAudioDevice(id: 5, name: "Aggregate Device", transport: .aggregate, inputChannelCount: 2)
        let virtual = DictationAudioDevice(id: 6, name: "Krisp Microphone", transport: .virtual, inputChannelCount: 1)
        assertFalse(
            DictationStartCuePolicy.playsOnKeyPress(recordedInput: airPods),
            "opening a headset's own mic flips it into call mode and would cut the click"
        )
        assertFalse(DictationStartCuePolicy.playsOnKeyPress(recordedInput: bluetoothLE), "Bluetooth LE headset")
        assertFalse(DictationStartCuePolicy.playsOnKeyPress(recordedInput: aggregate), "aggregate can wrap a headset")
        assertFalse(DictationStartCuePolicy.playsOnKeyPress(recordedInput: virtual), "virtual can wrap a headset")
        assertFalse(DictationStartCuePolicy.playsOnKeyPress(recordedInput: nil), "an input not seen yet")
    }
}
