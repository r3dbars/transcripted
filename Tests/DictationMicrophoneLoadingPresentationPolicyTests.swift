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

        assertEqual(copy.title, "Mic starting", "brief unready state should not flash switching copy")
        assertEqual(copy.detail, "Opening the selected mic.", "brief unready state should keep normal startup copy")
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

        assertEqual(copy.title, "Switching mic", "sustained recovery should still be visible")
        assertEqual(copy.detail, "Connecting to the new mic.", "real recovery should keep recovery detail")
    }

    runSuite("DictationMicrophoneLoadingPresentationPolicy suppresses brief retry flicker") {
        let copy = DictationMicrophoneLoadingPresentationPolicy.copy(
            elapsed: 0.2,
            deviceName: "MacBook Pro Microphone",
            isRecovering: true,
            inputFormatReady: false,
            startAttempts: 2
        )

        assertEqual(copy.title, "Mic starting", "brief route churn should keep the initial title stable")
        assertEqual(copy.detail, "Opening the selected mic.", "brief route churn should avoid flashing switching copy")
        assertNil(copy.status, "brief retry attempts should not flash a retry status before the switching delay")
    }

    runSuite("DictationMicrophoneLoadingPresentationPolicy shows retry at the switching boundary") {
        let copy = DictationMicrophoneLoadingPresentationPolicy.copy(
            elapsed: DictationMicrophoneLoadingPresentationPolicy.switchingCopyDelay,
            deviceName: "MacBook Pro Microphone",
            isRecovering: true,
            inputFormatReady: false,
            startAttempts: 2
        )

        assertEqual(copy.title, "Switching mic", "visible recovery should name the route change")
        assertEqual(copy.detail, "Connecting to the new mic.", "visible recovery should explain the wait")
        assertEqual(copy.status, "Retrying MacBook Pro Microphone", "retry status should arrive with the switching copy")
    }

    runSuite("DictationMicrophoneLoadingPresentationPolicy keeps retry status") {
        let copy = DictationMicrophoneLoadingPresentationPolicy.copy(
            elapsed: 2.0,
            deviceName: "MacBook Pro Microphone",
            isRecovering: false,
            inputFormatReady: false,
            startAttempts: 2
        )

        assertEqual(copy.title, "Mic starting", "a slow start with no live recovery is not a switch")
        assertEqual(copy.status, "Retrying MacBook Pro Microphone", "retry status should stay explicit")
    }

    runSuite("DictationMicrophoneLoadingPresentationPolicy never calls deferred readiness a switch") {
        // AirPods route chatter defers readiness after nearly every take; a
        // tester saw "Switching microphone" on every press with no mic change.
        let copy = DictationMicrophoneLoadingPresentationPolicy.copy(
            elapsed: 1.0,
            deviceName: "AirPods",
            isRecovering: false,
            inputFormatReady: false,
            startAttempts: 1
        )

        assertEqual(copy.title, "Mic starting", "deferred idle readiness keeps the normal start title")
        assertEqual(copy.detail, "Opening the selected mic.", "deferred idle readiness keeps the normal start detail")
    }
}
