import Foundation

@MainActor
func testDictationStartReadiness() async {
    runSuite("A start requested while Transcripted is frontmost takes the foreground plan") {
        let profile = DictationStartReadinessPolicy.profile(
            triggerRawValue: "menu",
            isAppActive: true
        )
        assertEqual(profile, .foreground, "the menu path must be byte-for-byte unchanged")
        assertFalse(profile.isBackgroundStart, "frontmost is not a background start")
        assertFalse(
            profile.allowsForegroundActivationEscalation,
            "an already-foreground start has nothing to activate"
        )
        assertEqual(profile.name, "foreground", "diagnostics name")
    }

    runSuite("A hotkey start from another app is prepared as a background start") {
        let profile = DictationStartReadinessPolicy.profile(
            triggerRawValue: "physical_key",
            isAppActive: false
        )
        assertTrue(profile.isBackgroundStart, "issue #1743's failing case")
        assertTrue(
            profile.allowsForegroundActivationEscalation,
            "a hotkey start may still escalate to the activation handshake"
        )
        assertEqual(profile.name, "background", "diagnostics name")
    }

    runSuite("The same hotkey pressed inside Transcripted takes the foreground plan") {
        // The reporter's workaround: foreground Transcripted first, then press
        // the hotkey. That start is indistinguishable from a menu start.
        assertEqual(
            DictationStartReadinessPolicy.profile(triggerRawValue: "physical_key", isAppActive: true),
            .foreground,
            "a hotkey pressed while frontmost is a foreground start"
        )
    }

    runSuite("The profile carries no CoreAudio timeouts") {
        // Deliberate. An earlier revision of this fix put the per-operation
        // fences on the profile and applied them by mutating "fence in
        // flight" properties on ParakeetEngine. That leaked into prewarm and
        // the recovery paths whenever they interleaved with a suspended
        // start, and the recovery restarts dropped back to the defaults
        // anyway. If this ever grows timeouts again, they have to be threaded
        // as parameters through `audioInputSnapshot` and
        // `runTimedAudioEngineWork`, not stashed on the engine.
        assertEqual(
            TranscriptedConstants.audioStartOperationTimeout,
            1_500_000_000,
            "the one audio-start fence, unchanged by this policy"
        )
        assertEqual(
            TranscriptedConstants.systemInputOperationTimeout,
            1_500_000_000,
            "the one system-input fence, unchanged by this policy"
        )
    }

    runSuite("App Nap is a property of the process, so any background start gets the plan") {
        // Not gated on the trigger: if Transcripted is not the active app, the
        // audio-engine queue can be napped no matter how the start was asked
        // for. Only the focus-stealing escalation is trigger-gated.
        let menuFromBackground = DictationStartReadinessPolicy.profile(
            triggerRawValue: "menu",
            isAppActive: false
        )
        assertTrue(menuFromBackground.isBackgroundStart, "background is background")
        assertFalse(
            menuFromBackground.allowsForegroundActivationEscalation,
            "a non-hotkey start must never steal the user's focus"
        )

        // `physical_key` is the only global-hotkey trigger anything emits —
        // ContextCaptureEngine uses it for push-to-talk press/release AND for
        // the hands-free toggle. `keyboard_shortcut` and `right_option_tap`
        // are declared on DictationTrigger but never constructed, so listing
        // them would be coverage this policy does not have.
        assertTrue(DictationStartReadinessPolicy.isHotkeyTrigger("physical_key"))
        assertFalse(DictationStartReadinessPolicy.isHotkeyTrigger("keyboard_shortcut"))
        assertFalse(DictationStartReadinessPolicy.isHotkeyTrigger("right_option_tap"))
        assertFalse(DictationStartReadinessPolicy.isHotkeyTrigger("menu"))
        assertFalse(DictationStartReadinessPolicy.isHotkeyTrigger("overlay_button"))
        assertFalse(DictationStartReadinessPolicy.isHotkeyTrigger("onboarding"))
        assertFalse(DictationStartReadinessPolicy.isHotkeyTrigger("session_cap"))
        assertFalse(DictationStartReadinessPolicy.isHotkeyTrigger("unknown"))
    }

    runSuite("App Nap suppression is reference counted and balanced") {
        let recorder = ActivityRecorder()
        let activity = DictationProcessActivity(
            begin: { options, reason in recorder.begin(options: options, reason: reason) },
            end: { token in recorder.end(token) }
        )

        assertFalse(activity.isHeld, "nothing is asserted before a session starts")
        assertEqual(activity.holderCount, 0, "the refcount starts at zero")

        activity.acquire(reason: "first")
        assertTrue(activity.isHeld, "a start takes the assertion")
        assertEqual(recorder.begins, 1, "exactly one ProcessInfo activity")
        assertTrue(activity.currentReason == "first", "reason is kept for diagnostics")
        assertEqual(recorder.lastReason, "first", "the reason reaches ProcessInfo")
        assertEqual(
            recorder.lastOptions,
            DictationProcessActivity.activityOptions,
            "the documented App Nap suppression options"
        )

        activity.acquire(reason: "second")
        assertEqual(recorder.begins, 1, "a joining holder does not open a second activity")
        assertEqual(activity.holderCount, 2, "both holders counted")

        activity.release()
        assertTrue(activity.isHeld, "the assertion outlives the first holder")
        assertEqual(recorder.ends, 0, "nothing ended while a session still needs it")

        activity.release()
        assertFalse(activity.isHeld, "the last holder ends it")
        assertEqual(recorder.ends, 1, "ended exactly once")
        assertTrue(activity.currentReason == nil, "reason cleared with the assertion")

        activity.release()
        assertEqual(recorder.ends, 1, "an unbalanced release is a no-op, not a double end")
        assertEqual(activity.holderCount, 0, "holder count never goes negative")

        activity.acquire(reason: "third")
        assertTrue(activity.isHeld, "a later session takes a fresh assertion")
        assertEqual(recorder.begins, 2, "a fresh activity, not the ended one")
    }

    runSuite("The hotkey trigger raw values still match DictationTrigger") {
        // `hotkeyTriggerRawValues` is raw strings so the policy stays free of
        // the AppKit-bound controller, which means nothing in the type system
        // catches a renamed raw value — escalation would just silently stop
        // happening. Check the strings against the real enum.
        for raw in DictationStartReadinessPolicy.hotkeyTriggerRawValues {
            assertNotNil(
                DictationTrigger(rawValue: raw),
                "\(raw) must still be a DictationTrigger raw value or escalation dies silently"
            )
        }

        // The raw values the suites below assert are NOT hotkeys have to be
        // real cases too, or those assertions pass for the wrong reason.
        for raw in ["keyboard_shortcut", "right_option_tap", "menu", "overlay_button", "onboarding", "session_cap"] {
            assertNotNil(DictationTrigger(rawValue: raw), "\(raw) must still be a DictationTrigger raw value")
        }

        assertEqual(DictationTrigger.physicalKey.rawValue, "physical_key", "the one global-hotkey trigger, named exactly")
    }

    runSuite("The App Nap assertion is not labelled with a stale profile") {
        // `isDictating` also flips true at the stop-finalization
        // readmissions, which re-enter a retained recording rather than
        // opening the microphone. They carry no readiness profile.
        var label = DictationProcessActivityLabel()
        label.startingMicrophone(DictationStartReadinessPolicy.profile(triggerRawValue: "physical_key", isAppActive: false))
        assertEqual(label.reason, "Transcripted dictation capture (background)", "a start names its own plan")
        label.sessionEnded()
        assertEqual(
            label.reason,
            "Transcripted dictation capture (stop finalization)",
            "a readmission after the session ended must not reuse the last start's plan"
        )
        label.startingMicrophone(.foreground)
        assertEqual(label.reason, "Transcripted dictation capture (foreground)", "the next real start names itself again")
    }

    runSuite("The cancel diagnostic names the stage the start was waiting on") {
        var clock = DictationPendingStartStageClock(now: 0)
        clock.enter(.startRequested, now: 10)
        clock.enter(.waitingForAudioRoute, now: 10.25)
        let ended = clock.end(now: 10.5)
        assertEqual(ended.stage, .waitingForAudioRoute, "what the pending start was waiting on when the key ended it")
        assertEqual(ended.msInStage, 250, "time in that stage, not since the request began")
        assertEqual(clock.stage, .idle, "reading it also ends it, so nothing reads a stage after teardown")

        let report = DictationEarlyReleaseCancelReport.context(
            trigger: DictationTrigger.physicalKey.rawValue,
            shortcutMode: .handsFree,
            pendingForMs: 450,
            pendingStage: ended.stage.rawValue,
            stagePendingForMs: ended.msInStage,
            startPlan: "background",
            appActive: false
        )
        assertEqual(report["pending_stage"], "waiting_for_audio_route", "the reporter needs to know what the start was waiting on")
        assertEqual(report["stage_pending_for_ms"], "250", "time in that stage")
        assertEqual(report["pending_for_ms"], "450", "time since the request began")
        assertEqual(report["duration_ms"], "450", "duration_ms stays for anything already reading it")
        assertEqual(
            Set(report.keys),
            ["trigger", "failure_kind", "shortcut_mode", "pending_for_ms", "duration_ms", "pending_stage",
             "stage_pending_for_ms", "start_plan", "app_active"],
            "no app-nap flag: the assertion is taken by every start, so such a flag would read true every time"
        )
    }

    runSuite("Each pending stage has the name a reporter pastes back") {
        assertEqual(
            DictationPendingStartStage.allCases.map(\.rawValue),
            ["idle", "start_requested", "awaiting_microphone_permission", "awaiting_model_warmup",
             "waiting_for_audio_route", "opening_microphone"],
            "each name points at a different bug, so none can be renamed silently"
        )
        assertEqual(DictationPendingStartStage(.openingMicrophone), .openingMicrophone, "the native open's own stage")
        assertEqual(DictationPendingStartStage(.waitingForAudioRoute), .waitingForAudioRoute, "a failed open waits for the route")
    }

    runSuite("The assertion suppresses App Nap without changing sleep policy") {
        let options = DictationProcessActivity.activityOptions
        assertTrue(
            options.contains(.latencyCritical),
            "latencyCritical is what stops timer coalescing for capture work"
        )
        assertTrue(
            options.contains(.userInitiatedAllowingIdleSystemSleep),
            "the process must read as doing user-initiated work"
        )
        assertFalse(
            options.contains(.idleSystemSleepDisabled),
            "dictation has no business keeping the machine awake"
        )
        assertFalse(
            options.contains(.idleDisplaySleepDisabled),
            "dictation has no business keeping the display awake"
        )
    }

    for nativeResult in [false, true] {
        await runSuite("Recovery wait to open reports the right stage on early cancel (native result: \(nativeResult))") {
            let openEntered = ParakeetAsyncInterleavingGate()
            let finishOpen = ParakeetAsyncInterleavingGate()
            var isCurrentSession = true
            var stage = DictationMicrophoneStartStage.waitingForAudioRoute.rawValue
            var stageEnteredAt = 0
            var now = 100 // The route wait already consumed 100ms.
            var stages: [DictationMicrophoneStartStage] = []

            let attempt = Task { @MainActor in
                await DictationMicrophoneStartReporting.run(
                    isCurrentSession: { isCurrentSession },
                    onStageChanged: {
                        stages.append($0)
                        stage = $0.rawValue
                        stageEnteredAt = now
                    },
                    start: {
                        await openEntered.open()
                        await finishOpen.wait()
                        return nativeResult
                    }
                )
            }
            await openEntered.wait()
            now = 125
            // This snapshot models the hotkey's diagnostic while the native
            // operation really is suspended, not a list of expected strings.
            assertEqual(stage, "opening_microphone", "a pending native open is not route waiting")
            assertEqual(now - stageEnteredAt, 25, "the open-stage clock excludes the earlier 100ms wait")
            attempt.cancel()
            isCurrentSession = false
            stage = "idle"
            await finishOpen.open()
            let result = await attempt.value
            assertEqual(result, nativeResult, "late native success remains visible to cancellation cleanup")
            assertEqual(stage, "idle", "late completion cannot relabel a cancelled session")
            assertEqual(stages, [.openingMicrophone], "cancelled failure cannot re-enter readiness waiting")
        }
    }

    await runSuite("A failed recovery open returns to waiting before focus recovery and retry") {
        var stages: [DictationMicrophoneStartStage] = [.waitingForAudioRoute]
        let failed = await DictationRecordingStartAttempt.run(
            start: {
                await DictationMicrophoneStartReporting.run(
                    isCurrentSession: { true },
                    onStageChanged: { stages.append($0) },
                    start: {
                        assertEqual(stages.last, .openingMicrophone, "mark opening before entering native work")
                        return false
                    }
                )
            },
            onFailure: {
                assertEqual(stages.last, .waitingForAudioRoute, "focus recovery is no longer timed as a native open")
            }
        )
        assertFalse(failed, "diagnostic reporting must not manufacture success")
        let retried = await DictationMicrophoneStartReporting.run(
            isCurrentSession: { true },
            onStageChanged: { stages.append($0) },
            start: { true }
        )
        assertTrue(retried, "successful retry preserves the native result")
        assertEqual(stages, [.waitingForAudioRoute, .openingMicrophone, .waitingForAudioRoute, .openingMicrophone],
                    "each attempt gets its own stage boundary, with no false wait after success")
    }

    await runSuite("A superseded native open cannot reset a newer session's diagnostic stage") {
        let openEntered = ParakeetAsyncInterleavingGate()
        let finishOpen = ParakeetAsyncInterleavingGate()
        let attemptSessionID = UUID()
        var currentSessionID = attemptSessionID
        var stage = "waiting_for_audio_route"
        let attempt = Task { @MainActor in
            await DictationMicrophoneStartReporting.run(
                isCurrentSession: { currentSessionID == attemptSessionID },
                onStageChanged: { stage = $0.rawValue },
                start: {
                    await openEntered.open()
                    await finishOpen.wait()
                    return false
                }
            )
        }
        await openEntered.wait()
        currentSessionID = UUID()
        stage = "start_requested"
        await finishOpen.open()
        let result = await attempt.value
        assertFalse(result, "the old attempt still returns its own result")
        assertEqual(stage, "start_requested", "identity guards protect a new session even without task cancellation")
    }

    runSuite("Recovery-loop stage reports only move the session that asked") {
        let session = UUID()
        var clock = DictationPendingStartStageClock(now: 0)
        clock.enter(.waitingForAudioRoute, now: 1)
        clock.enterReported(.openingMicrophone, requestingSessionID: session, currentSessionID: session,
                            isDictating: true, isCancelled: false, now: 2)
        assertEqual(clock.stage, .openingMicrophone, "the live session's native open reaches the early-cancel diagnostic")
        assertEqual(clock.enteredAt, 2, "and restarts the stage clock")

        clock.enterReported(.waitingForAudioRoute, requestingSessionID: UUID(), currentSessionID: session,
                            isDictating: true, isCancelled: false, now: 3)
        assertEqual(clock.stage, .openingMicrophone, "a late report from a superseded session is dropped")
        clock.enterReported(.waitingForAudioRoute, requestingSessionID: session, currentSessionID: session,
                            isDictating: false, isCancelled: false, now: 3)
        assertEqual(clock.stage, .openingMicrophone, "a report after the session ended is dropped")
        clock.enterReported(.waitingForAudioRoute, requestingSessionID: session, currentSessionID: session,
                            isDictating: true, isCancelled: true, now: 3)
        assertEqual(clock.stage, .openingMicrophone, "a report from a cancelled start is dropped")
        assertEqual(clock.enteredAt, 2, "none of them touched the clock")
    }
}

/// Stands in for `ProcessInfo.beginActivity`/`endActivity` so the reference
/// counting can be exercised without asserting anything on the real process.
private final class ActivityRecorder {
    private(set) var begins = 0
    private(set) var ends = 0
    private(set) var lastOptions: ProcessInfo.ActivityOptions = []
    private(set) var lastReason = ""

    func begin(options: ProcessInfo.ActivityOptions, reason: String) -> NSObjectProtocol {
        begins += 1
        lastOptions = options
        lastReason = reason
        return NSObject()
    }

    func end(_ token: NSObjectProtocol) {
        ends += 1
    }
}
