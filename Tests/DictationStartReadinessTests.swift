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
        // happening. Pin the strings against the enum's own declaration.
        let source = readSourceFixture("Sources/UI/Overlay/DictationSessionController.swift")
        let triggerEnum = sourceSlice(
            source,
            from: "enum DictationTrigger: String {",
            to: "@Published var isDictating"
        )
        assertFalse(triggerEnum.isEmpty, "the DictationTrigger declaration should be findable")

        for raw in DictationStartReadinessPolicy.hotkeyTriggerRawValues {
            assertTrue(
                triggerEnum.contains("= \"\(raw)\""),
                "\(raw) must still be a DictationTrigger raw value or escalation dies silently"
            )
        }

        // The raw values the suites below assert are NOT hotkeys have to be
        // real cases too, or those assertions pass for the wrong reason.
        for raw in ["keyboard_shortcut", "right_option_tap", "menu", "overlay_button", "onboarding", "session_cap"] {
            assertTrue(
                triggerEnum.contains("= \"\(raw)\""),
                "\(raw) must still be a DictationTrigger raw value"
            )
        }

        assertTrue(
            triggerEnum.contains("case physicalKey = \"physical_key\""),
            "the one global-hotkey trigger, named exactly"
        )
    }

    runSuite("The App Nap assertion is not labelled with a stale profile") {
        // `isDictating` also flips true at the two stop-finalization
        // readmissions, which re-enter a retained recording rather than
        // opening the microphone. They carry no readiness profile, so the
        // assertion's reason string reads from a separate label that those
        // sites set themselves.
        let source = readSourceFixture("Sources/UI/Overlay/DictationSessionController.swift")
        assertTrue(
            source.contains("reason: \"Transcripted dictation capture (\\(processActivityLabel))\""),
            "the reason must come from the label, not from the last start's profile"
        )
        assertEqual(
            source.components(separatedBy: "self.processActivityLabel = \"stop finalization\"").count - 1,
            2,
            "both readmission sites must label themselves before flipping isDictating"
        )
        for readmission in source.components(separatedBy: "self.isDictating = true").dropLast() {
            let precedingLine = readmission
                .split(separator: "\n", omittingEmptySubsequences: false)
                .last { !$0.trimmingCharacters(in: .whitespaces).isEmpty }
                .map { $0.trimmingCharacters(in: .whitespaces) } ?? ""
            assertEqual(
                precedingLine,
                "self.processActivityLabel = \"stop finalization\"",
                "every `self.isDictating = true` must be immediately preceded by its label"
            )
        }
    }

    runSuite("The cancel diagnostic names the stage instead of a constant boolean") {
        // DictationSessionController cannot be instantiated in the fast-test
        // runner, so pin the source-level shape of the one log line a #1743
        // reporter is asked to paste back.
        let source = readSourceFixture("Sources/UI/Overlay/DictationSessionController.swift")

        assertFalse(
            source.contains("app_nap_suppressed"),
            "the assertion is taken by the `isDictating` didSet, so any such flag logs true every time"
        )

        let cancelPath = sourceSlice(
            source,
            from: "private func cancelPendingDictationStartAfterEarlyRelease",
            to: "private func overlayStateName"
        )
        assertTrue(
            cancelPath.contains("\"pending_stage\": stage"),
            "the reporter needs to know what the pending start was waiting on"
        )
        assertTrue(
            cancelPath.contains("\"stage_pending_for_ms\""),
            "time in that stage, alongside time since the request began"
        )
        assertTrue(
            cancelPath.contains("\"pending_for_ms\"") && cancelPath.contains("\"duration_ms\""),
            "duration_ms stays for anything already reading it; pending_for_ms says what it means"
        )
        assertTrue(
            cancelPath.range(of: "let stage = pendingStartStage")
                .map { stageRead in
                    cancelPath.range(of: "isDictating = false").map { $0.lowerBound > stageRead.lowerBound } ?? false
                } ?? false,
            "the stage must be read before the session is torn down and the stage reset to idle"
        )

        // Every path a pending start can be sitting in has to name itself, or
        // `pending_stage` silently reports a stale earlier stage.
        for stage in [
            "start_requested",
            "awaiting_microphone_permission",
            "awaiting_model_warmup",
            "waiting_for_audio_route",
            "opening_microphone",
        ] {
            assertTrue(
                source.contains("enterPendingStartStage(\"\(stage)\")"),
                "\(stage) must be marked where the start enters it"
            )
        }
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

    runSuite("Recovery-loop microphone stage reporting reaches the session-scoped controller") {
        let speech = readSourceFixture("Sources/Speech/DictationSession.swift")
        let nativeStart = sourceSlice(speech, from: "func startDictationAudioRecording(", to: "func recordingStartPlan(")
        assertTrue(nativeStart.contains("await DictationMicrophoneStartReporting.run("),
                   "the executable reporting seam wraps production native starts")
        assertTrue(nativeStart.contains("startRecordingRecoveryAttempt()") && nativeStart.contains("startRecording()"),
                   "both forced and ordinary recovery-loop attempts are covered")
        let recoveryAttempt = sourceSlice(speech, from: "fileprivate func performStartAttempt(", to: "fileprivate func dictationContext(")
        assertTrue(recoveryAttempt.contains("isCurrentSession: isDictating"), "the loop's captured session predicate reaches reporting")
        assertTrue(recoveryAttempt.contains("onStartStageChanged: onStartStageChanged"), "the loop forwards the callback into the native open")
        let controller = readSourceFixture("Sources/UI/Overlay/DictationSessionController.swift")
        let stageCallback = sourceSlice(controller, from: "onStartStageChanged: { [weak self] stage in", to: "onWaitUpdate:")
        assertTrue(stageCallback.contains("self.currentDictationSessionID == sessionID") && stageCallback.contains("self.isDictating"),
                   "a late callback is scoped to the active requesting session")
        assertTrue(stageCallback.contains("self.enterPendingStartStage(stage.rawValue)"),
                   "the early-cancel diagnostic and stage clock receive the native transition")
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

private func sourceSlice(_ source: String, from start: String, to end: String) -> String {
    guard let startRange = source.range(of: start),
          let endRange = source.range(of: end, range: startRange.upperBound..<source.endIndex) else {
        return ""
    }
    return String(source[startRange.lowerBound..<endRange.lowerBound])
}
