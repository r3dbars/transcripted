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

    runSuite("DictationRecordingStartLifecyclePolicy cancels visible loading even without task handle") {
        let decision = DictationRecordingStartLifecyclePolicy.stopDecision(
            isLoadingOverlay: true,
            isListeningOverlay: false,
            hasRecordingStartTask: false,
            sttIsRecording: false
        )

        assertEqual(
            decision,
            .cancelPendingStart,
            "a release while the loading overlay is visible should cancel startup even if the task already cleared"
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

    runSuite("DictationRecordingStartFailurePolicy keeps normal startup cleanup lightweight") {
        let plan = DictationRecordingStartFailurePolicy.cleanupPlan(for: "audio_engine_start_failed")

        assertEqual(plan.outcome, "audio_engine_start_failed", "cleanup should preserve the original failure kind")
        assertTrue(plan.resetRuntimeSessionToIdle, "startup failures should clear active runtime state")
        assertTrue(plan.resetSpeechEngine, "startup failures should release the partial audio graph")
        assertFalse(plan.hardResetSpeechEngine, "normal start failures should not abandon the graph like a timeout")
        assertFalse(plan.reportBeforeCleanup, "normal failures can report after ordinary cleanup")
        assertFalse(plan.reportRuntimeStall, "handled startup failures should not become stall telemetry")
    }

    runSuite("DictationMicrophoneTimeoutPresentationPolicy names Bluetooth fallback failures") {
        let message = DictationMicrophoneTimeoutPresentationPolicy.message(
            deviceName: "MacBook Pro Microphone",
            startAttempts: 1,
            inputFormatReady: false,
            routeContext: [
                "default_input_class": "bluetooth",
                "default_output_class": "bluetooth",
                "selected_input_class": "built_in",
                "selection_overrode_default": "true",
                "selection_reason": "preferredBuiltInForBluetoothHeadset",
            ]
        )

        assertEqual(
            message,
            "Couldn't start the built-in microphone while Bluetooth audio was active. Try again, or choose a different input in System Settings.",
            "Bluetooth fallback timeouts should tell users what changed instead of blaming only the selected mic"
        )
    }

    runSuite("DictationMicrophoneTimeoutPresentationPolicy keeps generic fallback copy") {
        let message = DictationMicrophoneTimeoutPresentationPolicy.message(
            deviceName: "Studio Display Microphone",
            startAttempts: 0,
            inputFormatReady: false
        )

        assertEqual(
            message,
            "Couldn't reach Studio Display Microphone. Try selecting a different input in System Settings.",
            "non-Bluetooth route failures should keep the existing device-specific guidance"
        )
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

    runSuite("DictationActiveTaskCancellationPolicy keeps idle cancellation local") {
        let plan = DictationActiveTaskCancellationPolicy.plan(
            cancelRecording: false,
            recordingStartWasInFlight: false,
            sttIsRecording: false,
            sttIsTranscribing: false
        )

        assertTrue(plan.cancelStreamingTask, "idle streaming tasks can still be cancelled")
        assertFalse(plan.cancelSpeechEngine, "idle overlay cleanup should not reset the speech engine")
    }
}
