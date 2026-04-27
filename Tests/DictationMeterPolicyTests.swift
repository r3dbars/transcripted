import Foundation

func testDictationMeterPolicy() {
    runSuite("DictationMeterPolicy hides meter outside active recording") {
        let loading = DictationMeterPolicy.presentation(
            isListening: false,
            sttIsRecording: false,
            rawLevel: 0.8
        )
        assertEqual(loading, .init(isVisible: false, level: 0), "loading should not show stale audio")

        let starting = DictationMeterPolicy.presentation(
            isListening: true,
            sttIsRecording: false,
            rawLevel: 0.8
        )
        assertEqual(starting, .init(isVisible: false, level: 0), "listening UI should wait for real recording")

        let drafting = DictationMeterPolicy.presentation(
            isListening: false,
            sttIsRecording: true,
            rawLevel: 0.8
        )
        assertEqual(drafting, .init(isVisible: false, level: 0), "drafting should clear the meter")
    }

    runSuite("DictationMeterPolicy shows clamped level while listening and recording") {
        let visible = DictationMeterPolicy.presentation(
            isListening: true,
            sttIsRecording: true,
            rawLevel: 0.4
        )
        assertEqual(visible, .init(isVisible: true, level: 0.4), "active recording should show the live level")

        let high = DictationMeterPolicy.presentation(
            isListening: true,
            sttIsRecording: true,
            rawLevel: 4
        )
        assertEqual(high, .init(isVisible: true, level: 1), "raw levels should clamp high")

        let low = DictationMeterPolicy.presentation(
            isListening: true,
            sttIsRecording: true,
            rawLevel: -1
        )
        assertEqual(low, .init(isVisible: true, level: 0), "raw levels should clamp low")
    }
}
