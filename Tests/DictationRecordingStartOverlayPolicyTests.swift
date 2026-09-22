import Foundation

// Source-text pins: every suite above the last one here calls a real
// DictationRecordingStart*/DictationActiveTaskCancellationPolicy/DictationStartAvailabilityPolicy
// type directly, so it's genuine behavioral coverage. The final suite ("Unexpected meeting
// capture stop releases shared dictation mic") instead greps
// Sources/Meeting/MeetingSessionController.swift's private handleUnexpectedCaptureStop, because
// MeetingSessionController is the @MainActor ObservableObject that wires TranscriptedCore's live
// capture callbacks into the app and can't be constructed or driven in this Foundation-only
// runner. If you move or rewrite that function, update the two matched calls and the
// range-bounding marker comment ("// preserveQueuedTranscriptionJobsForShutdown") together.

func testDictationRecordingStartOverlayPolicy() {
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

    runSuite("Production decides the early-release message instead of hard-coding one") {
        let source = readSourceFixture("Sources/UI/Overlay/DictationSessionController.swift")
        guard let start = source.range(of: "func cancelPendingDictationStartAfterEarlyRelease("),
              let end = source.range(of: "func overlayStateName(", range: start.upperBound..<source.endIndex) else {
            assertTrue(false, "the early-release cancel path should remain present")
            return
        }
        let body = String(source[start.lowerBound..<end.lowerBound])
        assertTrue(
            body.contains("DictationEarlyReleasePresentationPolicy.message("),
            "the message the user reads must come from the policy, so #1743's tapped key keeps its own wording"
        )
        assertFalse(
            body.contains("showError(\"Mic wasn't ready yet"),
            "a hard-coded fallback next to the policy call would silently restore the misleading line"
        )
        assertTrue(
            body.contains("pendingForMs: startPendingForMs"),
            "the policy must read the same elapsed time the diagnostics report, not a separate measurement"
        )
        assertFalse(
            body.contains("HotkeyPreferences.dictationShortcutMode()"),
            "the legacy preference no longer identifies which physical key ended the session"
        )
        let hotkeySource = readSourceFixture("Sources/Capture/ContextCaptureEngine.swift")
        assertTrue(
            hotkeySource.contains("session.startDictation(sourceApp: frontApp, trigger: .physicalKey, shortcutMode: .pushToTalk)"),
            "the Push to Talk press must identify the actual shortcut in start diagnostics"
        )
        assertTrue(
            hotkeySource.contains("session.startDictation(sourceApp: sourceApp, trigger: trigger, shortcutMode: shortcutMode)"),
            "the Hands-Free toggle must identify the actual shortcut in start diagnostics"
        )
        assertTrue(
            hotkeySource.contains("routeDictationToggle(sourceApp: frontApp, trigger: .physicalKey, shortcutMode: .handsFree)"),
            "the hands-free key must route its real action into the stop path"
        )
        assertTrue(
            hotkeySource.contains("session.stopDictationAndPaste(trigger: .physicalKey, shortcutMode: .pushToTalk)"),
            "the Push to Talk release must route its real action into the stop path"
        )
        assertTrue(
            hotkeySource.contains("session.stopDictationAndPaste(trigger: trigger, shortcutMode: shortcutMode)"),
            "the hands-free toggle must forward its action into the session controller"
        )
        guard let startDiagnostics = source.range(of: "private func recordStartReadinessPrepared("),
              let endDiagnostics = source.range(of: "private func recordDictationStarted(", range: startDiagnostics.upperBound..<source.endIndex) else {
            assertTrue(false, "the start diagnostics should remain present")
            return
        }
        let startDiagnosticsBody = String(source[startDiagnostics.lowerBound..<endDiagnostics.lowerBound])
        assertTrue(
            startDiagnosticsBody.contains("extra[\"shortcut_mode\"] = shortcutMode.rawValue"),
            "start diagnostics use the actual key action when one exists"
        )
        assertFalse(
            startDiagnosticsBody.contains("HotkeyPreferences.dictationShortcutMode()"),
            "start diagnostics must not infer the physical key from a legacy preference"
        )
    }

    runSuite("A new dictation session can stop after an earlier session") {
        var gate = DictationStopFinalizationGate()
        assertTrue(gate.admit(sessionID: UUID()), "initial session can stop")
        assertTrue(gate.admit(sessionID: UUID()), "different-session finalization must not be fenced by a stale ID")
    }

    runSuite("Production fences repeated Stop before the loading-state cancel decision") {
        do {
            let source = try String(
                contentsOf: repoFixtureURL("Sources/UI/Overlay/DictationSessionController.swift"),
                encoding: .utf8
            )
            guard let stopStart = source.range(of: "func stopDictationAndPaste("),
                  let stopEnd = source.range(of: "func cancelDictation(", range: stopStart.upperBound..<source.endIndex),
                  let fence = source.range(of: "if stopFinalizationGate.admittedSessionID == currentDictationSessionID", range: stopStart.upperBound..<stopEnd.lowerBound),
                  let lifecycle = source.range(of: "DictationRecordingStartLifecyclePolicy.stopDecision(", range: stopStart.upperBound..<stopEnd.lowerBound),
                  let admission = source.range(of: "stopFinalizationGate.admit(sessionID: currentDictationSessionID)", range: stopStart.upperBound..<stopEnd.lowerBound),
                  let oldTaskCancel = source.range(of: "streamingTask?.cancel()", range: stopStart.upperBound..<stopEnd.lowerBound),
                  let persist = source.range(of: "DictationStoppedAudioRecoveryStore.persist(", range: stopStart.upperBound..<stopEnd.lowerBound) else {
                assertTrue(false, "the production Stop path should expose its admission, cancellation and checkpoint boundaries")
                return
            }
            assertTrue(
                fence.lowerBound < lifecycle.lowerBound &&
                    lifecycle.lowerBound < admission.lowerBound &&
                    admission.lowerBound < oldTaskCancel.lowerBound &&
                    oldTaskCancel.lowerBound < persist.lowerBound,
                "a duplicate Stop must return before loading can cancel startup or a detached WAV write"
            )
            let interruption = source[stopEnd.lowerBound..<source.endIndex]
            guard let checkpointWait = interruption.range(of: "await interruptedCheckpointSignal?.wait()"),
                  let sessionGuard = interruption.range(of: "self.currentDictationSessionID == interruptedSessionID", range: checkpointWait.upperBound..<interruption.endIndex),
                  let reset = interruption.range(of: "self.stopFinalizationGate.reset()", range: checkpointWait.upperBound..<interruption.endIndex) else {
                assertTrue(false, "explicit interrupted-audio retry must wait for the previous stop owner before readmission")
                return
            }
            assertTrue(
                checkpointWait.lowerBound < sessionGuard.lowerBound && sessionGuard.lowerBound < reset.lowerBound,
                "old checkpoint write/cleanup must finish and session ownership must still hold before readmission"
            )
        } catch {
            assertTrue(false, "production controller source should be readable: \(error)")
        }
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

    runSuite("Unexpected meeting capture stop releases shared dictation mic") {
        let source = (try? String(
            contentsOfFile: "Sources/Meeting/MeetingSessionController.swift",
            encoding: .utf8
        )) ?? ""
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

    runSuite("DictationSessionController clears the start-task handle on the recovery-path start too") {
        let source = readSourceFixture("Sources/UI/Overlay/DictationSessionController.swift")
        guard let started = source.range(of: "case .started:"),
              let nextCase = source.range(of: "case .timedOut(let info):", range: started.upperBound..<source.endIndex) else {
            assertTrue(false, "the recovery-path .started branch should remain present")
            return
        }
        let body = String(source[started.lowerBound..<nextCase.lowerBound])
        assertTrue(
            body.contains("recordingStartRetryTask = nil"),
            "a stale start handle makes a push-to-talk release during device recovery read as cancel-pending-start and discard preserved audio"
        )
    }
}
