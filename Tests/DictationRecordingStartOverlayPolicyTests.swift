import Foundation

@MainActor
func testDictationRecordingStartOverlayPolicy() async {
    runSuite("A delayed checkpoint admits only one stop for the same session") {
        var gate = DictationStopFinalizationGate()
        let sessionID = UUID()
        assertTrue(gate.admit(sessionID: sessionID), "first stop owns the capture/checkpoint/finalization chain")
        assertFalse(gate.admit(sessionID: sessionID), "a repeated stop cannot cancel its owner's delayed WAV write")
        assertFalse(gate.admit(sessionID: sessionID), "the same session remains fenced through transcription and delivery")
        gate.reset()
        assertTrue(gate.admit(sessionID: sessionID), "an explicit interrupted-audio retry can readmit after the old task has settled")
    }

    runSuite("A tapped Push to Talk key is not told the microphone wasn't ready") {
        // The three real failures from #1743, off the reporter's own machine.
        for pendingForMs in [22, 72, 76] {
            assertEqual(
                DictationEarlyReleasePresentationPolicy.message(
                    shortcutMode: .pushToTalk,
                    pendingForMs: pendingForMs
                ),
                DictationEarlyReleasePresentationPolicy.shortTapMessage,
                "a \(pendingForMs)ms Push to Talk release is a tap, and blaming the mic sent that reporter swapping hardware for five days"
            )
        }
    }

    runSuite("A genuinely stalled Push to Talk start still gets the honest message") {
        assertEqual(
            DictationEarlyReleasePresentationPolicy.message(
                shortcutMode: .pushToTalk,
                pendingForMs: DictationEarlyReleasePresentationPolicy.shortTapThresholdMs
            ),
            DictationEarlyReleasePresentationPolicy.microphoneNotReadyMessage,
            "the threshold is exclusive: at it, the key was held long enough that a slow start is the better explanation"
        )
        assertEqual(
            DictationEarlyReleasePresentationPolicy.message(shortcutMode: .pushToTalk, pendingForMs: 4_000),
            DictationEarlyReleasePresentationPolicy.microphoneNotReadyMessage,
            "four seconds of holding is a stalled microphone open, and telling that user to hold the key would be wrong"
        )
    }

    runSuite("Hands-free keeps the generic message at every duration") {
        // Hands-free reaches the same branch on its second press, but that
        // press is a double-tap, not a too-short hold. "Hold the key" would
        // be actively wrong advice for a mode you press twice.
        for pendingForMs in [22, 249, 250, 4_000] {
            assertEqual(
                DictationEarlyReleasePresentationPolicy.message(
                    shortcutMode: .handsFree,
                    pendingForMs: pendingForMs
                ),
                DictationEarlyReleasePresentationPolicy.microphoneNotReadyMessage,
                "hands-free at \(pendingForMs)ms must not be told to hold a key it presses twice"
            )
        }
    }

    runSuite("An unknown physical shortcut never receives Push to Talk advice") {
        assertEqual(
            DictationEarlyReleasePresentationPolicy.message(shortcutMode: nil, pendingForMs: 22),
            DictationEarlyReleasePresentationPolicy.microphoneNotReadyMessage,
            "missing action evidence must not be guessed from the legacy shortcut preference"
        )
    }

    runSuite("The early-release report names the key action that ended the session") {
        for mode in [DictationShortcutMode.pushToTalk, .handsFree] {
            let context = earlyReleaseContext(shortcutMode: mode, pendingForMs: 22)
            assertEqual(context["shortcut_mode"], mode.rawValue, "the key action that ended the session")
            assertEqual(context["pending_for_ms"], "22", "the elapsed time the message is decided from")
        }
        assertEqual(
            earlyReleaseContext(shortcutMode: nil, pendingForMs: 22)["shortcut_mode"],
            "unknown",
            "no action evidence is said plainly, not guessed from the legacy preference"
        )
    }

    runSuite("The physical keys tell the session which shortcut acted") {
        let pushToTalk = RouterFake()
        pushToTalk.router.pushToTalkPressed()
        pushToTalk.isDictating = true
        pushToTalk.router.pushToTalkReleased()
        assertEqual(
            pushToTalk.events,
            ["start physical_key push_to_talk", "stop physical_key push_to_talk"],
            "the Push to Talk press and release name their real action in start and stop diagnostics"
        )

        let handsFree = RouterFake()
        handsFree.router.handsFreePressed()
        handsFree.isDictating = true
        handsFree.router.handsFreePressed()
        assertEqual(
            handsFree.events,
            ["start physical_key hands_free", "stop physical_key hands_free"],
            "the hands-free key routes its real action into both the start and the stop path"
        )

        let idle = RouterFake()
        idle.router.pushToTalkReleased()
        idle.isDictating = true
        idle.router.pushToTalkPressed()
        assertEqual(idle.events, [], "a release with nothing running, or a press while already dictating, does nothing")
    }

    runSuite("Start diagnostics name the key action only when a shortcut started the take") {
        let pressed = DictationStartReadinessPolicy.preparedDiagnostics(
            triggerRawValue: "physical_key",
            isAppActive: false,
            profile: DictationStartReadinessPolicy.profile(triggerRawValue: "physical_key", isAppActive: false),
            appNapHolders: 1,
            shortcutMode: .pushToTalk
        )
        assertEqual(pressed["shortcut_mode"], "push_to_talk", "start diagnostics use the actual key action")
        assertEqual(pressed["start_plan"], "background", "and the plan the start was prepared with")
        assertEqual(pressed["activation_escalation_allowed"], "true", "a hotkey from another app may escalate")
        let menu = DictationStartReadinessPolicy.preparedDiagnostics(
            triggerRawValue: "menu",
            isAppActive: true,
            profile: .foreground,
            appNapHolders: 2,
            shortcutMode: nil
        )
        assertNil(menu["shortcut_mode"], "a menu start has no physical key to name")
        assertEqual(menu["app_nap_holders"], "2", "the holder count, which does vary between starts")
    }

    runSuite("A new dictation session can stop after an earlier session") {
        var gate = DictationStopFinalizationGate()
        assertTrue(gate.admit(sessionID: UUID()), "initial session can stop")
        assertTrue(gate.admit(sessionID: UUID()), "different-session finalization must not be fenced by a stale ID")
    }

    runSuite("A repeated Stop is fenced before the loading-state cancel decision") {
        let fake = StopRoutingFake()
        fake.isAlreadyFinalizing = true
        assertEqual(
            DictationStopRequestRouting.route(trigger: .physicalKey, shortcutMode: .pushToTalk, fake.steps()),
            .ignoreAlreadyFinalizing,
            "a duplicate Stop must return before loading can cancel startup or a detached WAV write"
        )
        let first = StopRoutingFake()
        assertEqual(
            DictationStopRequestRouting.route(trigger: .physicalKey, shortcutMode: .pushToTalk, first.steps()),
            .proceed,
            "only a stop the session hasn't admitted yet reaches the loading-state decision"
        )
        let notDictating = StopRoutingFake()
        notDictating.isDictating = false
        assertEqual(DictationStopRequestRouting.route(trigger: .menu, shortcutMode: nil, notDictating.steps()),
                    .ignoreNotDictating, "no session, nothing to stop")
        assertEqual(notDictating.events, ["dictating?"], "and nothing else is checked")
    }

    runSuite("A hands-free press after the take stopped asks for the next take") {
        let fake = StopRoutingFake()
        fake.remembersNextStart = true
        assertEqual(DictationStopRequestRouting.route(trigger: .physicalKey, shortcutMode: .handsFree, fake.steps()),
                    .rememberedAsNextStart, "not another stop")
        assertEqual(fake.events, ["dictating?", "remember?"], "remembered before the finalizing fence")

        let pushToTalk = StopRoutingFake()
        pushToTalk.remembersNextStart = true
        _ = DictationStopRequestRouting.route(trigger: .physicalKey, shortcutMode: .pushToTalk, pushToTalk.steps())
        assertFalse(pushToTalk.events.contains("remember?"), "a Push to Talk release is always a stop, never a next press")
        let menu = StopRoutingFake()
        menu.remembersNextStart = true
        _ = DictationStopRequestRouting.route(trigger: .menu, shortcutMode: .handsFree, menu.steps())
        assertFalse(menu.events.contains("remember?"), "only the physical key toggles")
    }

    await runSuite("An interrupted-audio retry waits for the old stop before readmitting") {
        var events: [String] = []
        let outcome = await DictationInterruptedAudioReadmission.run(readmissionSteps(into: { events.append($0) }))
        assertEqual(outcome, .readmitted, "the retained recording is readmitted")
        assertEqual(
            events,
            ["wait for checkpoint", "owner?", "recording?", "reset fence", "readmit"],
            "old checkpoint write/cleanup must finish and session ownership must still hold before readmission"
        )

        events = []
        var superseded = readmissionSteps(into: { events.append($0) })
        superseded.stillOwnsRecording = { events.append("owner?"); return false }
        assertEqual(await DictationInterruptedAudioReadmission.run(superseded), .superseded, "a newer take owns the session now")
        assertFalse(events.contains("reset fence"), "the stop fence stays with the newer take")

        events = []
        var gone = readmissionSteps(into: { events.append($0) })
        gone.hasRecoverableRecording = { events.append("recording?"); return false }
        assertEqual(await DictationInterruptedAudioReadmission.run(gone), .audioGone, "the captured audio is no longer there")
        assertEqual(events, ["wait for checkpoint", "owner?", "recording?", "audio gone"], "said plainly, with nothing readmitted")
    }

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
            hasStartupTask: false,
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
            hasStartupTask: false,
            hasRecordingStartTask: false,
            sttIsRecording: false
        )

        assertEqual(
            decision,
            .cancelPendingStart,
            "a release while the loading overlay is visible should cancel startup even if the task already cleared"
        )
    }

    runSuite("DictationRecordingStartLifecyclePolicy cancels mini warmup before loading reveal") {
        let decision = DictationRecordingStartLifecyclePolicy.stopDecision(
            isLoadingOverlay: false,
            isListeningOverlay: false,
            hasStartupTask: true,
            hasRecordingStartTask: false,
            sttIsRecording: false
        )

        assertEqual(
            decision,
            .cancelPendingStart,
            "a stop during delayed mini cursor model warmup should cancel startup before recording begins"
        )
    }

    runSuite("DictationRecordingStartLifecyclePolicy stops once recording is active") {
        let decision = DictationRecordingStartLifecyclePolicy.stopDecision(
            isLoadingOverlay: false,
            isListeningOverlay: false,
            hasStartupTask: true,
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
            hasStartupTask: false,
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
            "Built-in mic unavailable. Choose another input.",
            "fallback timeouts should name the failed selected input without claiming Bluetooth caused the failure"
        )
    }

    runSuite("DictationMicrophoneTimeoutPresentationPolicy names immediate Bluetooth fallback start failures") {
        let message = DictationMicrophoneTimeoutPresentationPolicy.message(
            deviceName: "MacBook Pro Microphone",
            startAttempts: 0,
            inputFormatReady: true,
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
            "Built-in mic unavailable. Choose another input.",
            "fallback start failures should identify the unavailable built-in microphone"
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
            "Selected mic unavailable. Choose another input.",
            "non-Bluetooth route failures should keep a short input-change path"
        )
    }

    runSuite("DictationMicrophoneTimeoutPresentationPolicy keeps generic retry copy short") {
        let message = DictationMicrophoneTimeoutPresentationPolicy.message(
            deviceName: "MacBook Pro Microphone",
            startAttempts: 1,
            inputFormatReady: true
        )

        assertEqual(
            message,
            "Mic didn't start. Try again or choose another input.",
            "generic start failures should keep one visible retry path"
        )
    }

    runSuite("DictationActiveTaskCancellationPolicy cancels caller without tearing down inference") {
        let plan = DictationActiveTaskCancellationPolicy.plan(
            cancelRecording: true,
            recordingStartWasInFlight: false,
            sttIsRecording: false,
            sttIsTranscribing: true
        )

        assertTrue(plan.cancelStreamingTask, "queued inference must receive caller cancellation")
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

    runSuite("DictationStartAvailabilityPolicy allows dictation during active meeting capture") {
        assertNil(
            DictationStartAvailabilityPolicy.unavailableReason(
                hasActiveMeetingCapture: true,
                canShareMeetingMic: true,
                isSpeakerReviewPending: false
            ),
            "dictation should borrow the active meeting microphone stream"
        )
    }

    runSuite("DictationStartAvailabilityPolicy waits while meeting capture finalizes") {
        assertEqual(
            DictationStartAvailabilityPolicy.unavailableReason(
                hasActiveMeetingCapture: true,
                canShareMeetingMic: false,
                isSpeakerReviewPending: false
            ),
            DictationStartAvailabilityPolicy.meetingFinishingMessage,
            "dictation should not open a second audio graph while meeting capture tears down"
        )
    }

    runSuite("DictationStartAvailabilityPolicy allows dictation during speaker review") {
        assertNil(
            DictationStartAvailabilityPolicy.unavailableReason(
                hasActiveMeetingCapture: false,
                canShareMeetingMic: false,
                isSpeakerReviewPending: true
            ),
            "speaker review alone should not block dictation"
        )
    }

    runSuite("DictationStartAvailabilityPolicy allows dictation when meeting capture is idle") {
        assertNil(
            DictationStartAvailabilityPolicy.unavailableReason(
                hasActiveMeetingCapture: false,
                canShareMeetingMic: false,
                isSpeakerReviewPending: false
            ),
            "idle meeting state should not block dictation"
        )
    }

    // Still source-text, deliberately. MeetingSessionController can't be
    // built in the fast runner, and the same handler is pinned by
    // MeetingSessionUIPolicyTests, which the meeting lane (b09) owns.
    // Convert both together once that lands.
    runSuite("Unexpected meeting capture stop releases shared dictation mic") {
        let source = readSourceFixture("Sources/Meeting/MeetingSessionController.swift")
        guard let start = source.range(of: "private func handleUnexpectedCaptureStop"),
              let end = source.range(of: "// preserveQueuedTranscriptionJobsForShutdown", range: start.upperBound..<source.endIndex) else {
            assertTrue(false, "unexpected capture-stop handler should remain present")
            return
        }
        let body = String(source[start.lowerBound..<end.lowerBound])
        assertTrue(body.contains("clearSharedDictationMicRelay()"), "unexpected stop should drain the shared PCM relay")
        assertTrue(
            body.contains("resumeRegularRecordingAfterSharedMeetingMicEndedIfNeeded"),
            "unexpected stop should resume any in-flight dictation on the regular mic"
        )
        guard let recordingGuard = body.range(of: "guard case .recording = state"),
              let leaveRecording = body.range(of: "transition(to: .stoppingRecording, reason: \"unexpected_capture_stop\")"),
              let firstAwait = body.range(of: "await capture.flushSharedDictationMicHandler()") else {
            assertTrue(false, "unexpected stop must leave .recording before any await")
            return
        }
        assertTrue(
            recordingGuard.lowerBound < leaveRecording.lowerBound
                && leaveRecording.lowerBound < firstAwait.lowerBound,
            "unexpected stop must enter .stoppingRecording before flush/preserve awaits"
        )
    }
}

@MainActor
private final class RouterFake {
    var isDictating = false
    private(set) var events: [String] = []

    var router: DictationHotkeyRouter {
        DictationHotkeyRouter(
            isDictating: { self.isDictating },
            rememberStartPressIfFinishing: { _, _ in false },
            dropQueuedPushToTalkStart: { false },
            start: { trigger, mode in self.events.append("start \(trigger.rawValue) \(mode.rawValue)") },
            stop: { trigger, mode in self.events.append("stop \(trigger.rawValue) \(mode.rawValue)") }
        )
    }
}

@MainActor
private final class StopRoutingFake {
    var isDictating = true
    var remembersNextStart = false
    var isAlreadyFinalizing = false
    private(set) var events: [String] = []

    func steps() -> DictationStopRequestRouting.Steps {
        DictationStopRequestRouting.Steps(
            isDictating: { self.events.append("dictating?"); return self.isDictating },
            rememberHandsFreePressAsNextStart: { self.events.append("remember?"); return self.remembersNextStart },
            isAlreadyFinalizing: { self.events.append("finalizing?"); return self.isAlreadyFinalizing }
        )
    }
}

private func earlyReleaseContext(shortcutMode: DictationShortcutMode?, pendingForMs: Int) -> [String: String] {
    DictationEarlyReleaseCancelReport.context(
        trigger: DictationTrigger.physicalKey.rawValue,
        shortcutMode: shortcutMode,
        pendingForMs: pendingForMs,
        pendingStage: DictationPendingStartStage.openingMicrophone.rawValue,
        stagePendingForMs: 10,
        startPlan: "background",
        appActive: false
    )
}

@MainActor
private func readmissionSteps(into record: @escaping @MainActor (String) -> Void) -> DictationInterruptedAudioReadmission.Steps {
    DictationInterruptedAudioReadmission.Steps(
        waitForInterruptedCheckpoint: { record("wait for checkpoint") },
        stillOwnsRecording: { record("owner?"); return true },
        hasRecoverableRecording: { record("recording?"); return true },
        audioGone: { record("audio gone") },
        resetStopFence: { record("reset fence") },
        readmit: { record("readmit") }
    )
}
