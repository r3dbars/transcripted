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

    runSuite("DictationRecordingStartFailurePolicy treats microphone timeout as a handled startup failure") {
        let plan = DictationRecordingStartFailurePolicy.cleanupPlan(for: "microphone_start_timeout")

        assertEqual(plan.outcome, "microphone_start_timeout", "cleanup should keep the concrete failure outcome")
        assertTrue(plan.resetRuntimeSessionToIdle, "handled mic-start failures should not leave an active runtime session")
        assertTrue(plan.resetSpeechEngine, "failed startup should release the partial audio graph")
        assertTrue(plan.hardResetSpeechEngine, "mic-start timeout cleanup must abandon the blocked CoreAudio graph instead of queuing behind it")
        assertTrue(plan.reportBeforeCleanup, "mic-start timeout telemetry should fire before audio cleanup can block")
        assertFalse(plan.reportRuntimeStall, "the timeout event already reports this failure; it should not also emit app.session_stall_detected")
    }

    runSuite("DictationActiveTaskCancellationPolicy leaves active inference alone") {
        let plan = DictationActiveTaskCancellationPolicy.plan(
            cancelRecording: true,
            recordingStartWasInFlight: false,
            sttIsRecording: false,
            sttIsTranscribing: true
        )

        assertFalse(plan.cancelStreamingTask, "active CoreML transcription should be allowed to finish")
        assertFalse(plan.cancelSpeechEngine, "active CoreML transcription should not race engine cleanup")
    }

    runSuite("DictationActiveTaskCancellationPolicy still cancels recording and pending starts") {
        let recordingPlan = DictationActiveTaskCancellationPolicy.plan(
            cancelRecording: true,
            recordingStartWasInFlight: false,
            sttIsRecording: true,
            sttIsTranscribing: false
        )
        let pendingStartPlan = DictationActiveTaskCancellationPolicy.plan(
            cancelRecording: true,
            recordingStartWasInFlight: true,
            sttIsRecording: false,
            sttIsTranscribing: false
        )

        assertTrue(recordingPlan.cancelStreamingTask, "non-transcribing work can still be cancelled")
        assertTrue(recordingPlan.cancelSpeechEngine, "active recording cancel should still stop the speech engine")
        assertTrue(pendingStartPlan.cancelSpeechEngine, "pending CoreAudio starts should still be cancelled")
    }
}
