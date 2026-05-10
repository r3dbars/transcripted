import Foundation

func testDictationRecordingStartOverlayPolicy() {
    runSuite("DictationRecordingStartOverlayPolicy skips loading when the microphone is already ready") {
        let plan = DictationRecordingStartOverlayPolicy.plan(
            isRecovering: false,
            inputFormatReady: true
        )

        assertEqual(
            plan,
            .skipLoadingAndStartRecording,
            "ready microphone startup should not flash the loading overlay"
        )
    }

    runSuite("DictationRecordingStartOverlayPolicy keeps loading during device recovery") {
        let plan = DictationRecordingStartOverlayPolicy.plan(
            isRecovering: true,
            inputFormatReady: false
        )

        assertEqual(
            plan,
            .showLoadingWhileWaiting,
            "active recovery should still show waiting UI"
        )
    }

    runSuite("DictationRecordingStartOverlayPolicy keeps loading when the route is still unready") {
        let plan = DictationRecordingStartOverlayPolicy.plan(
            isRecovering: false,
            inputFormatReady: false
        )

        assertEqual(
            plan,
            .showLoadingWhileWaiting,
            "an unready input format should still wait instead of pretending the mic is live"
        )
    }

    runSuite("DictationRecordingStartLifecyclePolicy cancels a fast start that is still in flight") {
        let decision = DictationRecordingStartLifecyclePolicy.stopDecision(
            isLoadingOverlay: false,
            isListeningOverlay: false,
            hasRecordingStartTask: true,
            sttIsRecording: false
        )

        assertEqual(
            decision,
            .cancelPendingStart,
            "a quick push-to-talk release before CoreAudio flips recording on should cancel the pending start"
        )
    }

    runSuite("DictationRecordingStartLifecyclePolicy stops once recording is active") {
        let decision = DictationRecordingStartLifecyclePolicy.stopDecision(
            isLoadingOverlay: false,
            isListeningOverlay: false,
            hasRecordingStartTask: true,
            sttIsRecording: true
        )

        assertEqual(
            decision,
            .stopRecording,
            "once CoreAudio is recording the same stop request should transcribe instead of cancelling"
        )
    }

    runSuite("DictationRecordingStartLifecyclePolicy ignores inactive compact overlay stops") {
        let decision = DictationRecordingStartLifecyclePolicy.stopDecision(
            isLoadingOverlay: false,
            isListeningOverlay: false,
            hasRecordingStartTask: false,
            sttIsRecording: false
        )

        assertEqual(
            decision,
            .ignoreInactive,
            "idle compact overlay stops should stay ignored"
        )
    }
}
