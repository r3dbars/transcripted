import Foundation

func testDictationMicrophoneLoadingPresentationPolicy() {
    runSuite("DictationMicrophoneLoadingPresentationPolicy hides instant route flicker") {
        let copy = DictationMicrophoneLoadingPresentationPolicy.copy(
            elapsed: 0,
            deviceName: "MacBook Pro Microphone",
            isRecovering: false,
            inputFormatReady: false,
            startAttempts: 0
        )

        assertEqual(copy.title, "Starting microphone", "brief unready state should not flash switching copy")
        assertEqual(copy.detail, "Opening the selected audio input.", "brief unready state should keep normal startup copy")
        assertEqual(copy.status, nil, "instant startup should not show a retry status")
    }

    runSuite("DictationMicrophoneLoadingPresentationPolicy shows switching after real recovery delay") {
        let copy = DictationMicrophoneLoadingPresentationPolicy.copy(
            elapsed: DictationMicrophoneLoadingPresentationPolicy.switchingCopyDelay,
            deviceName: "MacBook Pro Microphone",
            isRecovering: true,
            inputFormatReady: false,
            startAttempts: 0
        )

        assertEqual(copy.title, "Switching microphone", "sustained recovery should still be visible")
        assertEqual(copy.detail, "Connecting to the new audio device.", "real recovery should keep recovery detail")
    }

    runSuite("DictationMicrophoneLoadingPresentationPolicy keeps retry status") {
        let copy = DictationMicrophoneLoadingPresentationPolicy.copy(
            elapsed: 2.0,
            deviceName: "MacBook Pro Microphone",
            isRecovering: false,
            inputFormatReady: false,
            startAttempts: 2
        )

        assertEqual(copy.title, "Switching microphone", "long unready state should name the route switch")
        assertEqual(copy.status, "Retrying MacBook Pro Microphone", "retry status should stay explicit")
    }
}
