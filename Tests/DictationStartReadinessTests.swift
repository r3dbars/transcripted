import Foundation

@MainActor
func testDictationStartReadiness() async {
    runSuite("A start requested while Transcripted is frontmost keeps today's budgets") {
        let profile = DictationStartReadinessPolicy.profile(
            triggerRawValue: "menu",
            isAppActive: true
        )
        assertEqual(profile, .foreground, "the menu path must be byte-for-byte unchanged")
        assertFalse(profile.isBackgroundStart, "frontmost is not a background start")
        assertEqual(
            profile.audioStartOperationTimeoutNanoseconds,
            TranscriptedConstants.audioStartOperationTimeout,
            "foreground keeps the original CoreAudio fence"
        )
        assertEqual(
            profile.systemInputOperationTimeoutNanoseconds,
            TranscriptedConstants.systemInputOperationTimeout,
            "foreground keeps the original system-input fence"
        )
        assertEqual(
            profile.recoveryBudget,
            TranscriptedConstants.dictationRecoveryBudget,
            "foreground keeps the original wait budget"
        )
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
            profile.audioStartOperationTimeoutNanoseconds
                > TranscriptedConstants.audioStartOperationTimeout,
            "a background HAL open gets a wider fence than a foreground one"
        )
        assertTrue(
            profile.systemInputOperationTimeoutNanoseconds
                > TranscriptedConstants.systemInputOperationTimeout,
            "the route-selection lookup is on the same start path and needs the same room"
        )
        assertTrue(
            profile.recoveryBudget > TranscriptedConstants.dictationRecoveryBudget,
            "the wait budget has to grow with the fence or only one attempt fits"
        )
        assertTrue(
            profile.allowsForegroundActivationEscalation,
            "a hotkey start may still escalate to the activation handshake"
        )
        assertEqual(profile.name, "background", "diagnostics name")
    }

    runSuite("The same hotkey pressed inside Transcripted takes the foreground plan") {
        // The reporter's workaround: foreground Transcripted first, then press
        // the hotkey. That start is indistinguishable from a menu start and
        // must not pay for background preparation it does not need.
        for trigger in ["physical_key", "keyboard_shortcut", "right_option_tap"] {
            assertEqual(
                DictationStartReadinessPolicy.profile(triggerRawValue: trigger, isAppActive: true),
                .foreground,
                "\(trigger) while frontmost is a foreground start"
            )
        }
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

        assertTrue(DictationStartReadinessPolicy.isHotkeyTrigger("physical_key"))
        assertTrue(DictationStartReadinessPolicy.isHotkeyTrigger("keyboard_shortcut"))
        assertTrue(DictationStartReadinessPolicy.isHotkeyTrigger("right_option_tap"))
        assertFalse(DictationStartReadinessPolicy.isHotkeyTrigger("menu"))
        assertFalse(DictationStartReadinessPolicy.isHotkeyTrigger("overlay_button"))
        assertFalse(DictationStartReadinessPolicy.isHotkeyTrigger("onboarding"))
        assertFalse(DictationStartReadinessPolicy.isHotkeyTrigger("session_cap"))
        assertFalse(DictationStartReadinessPolicy.isHotkeyTrigger("unknown"))
    }

    runSuite("Every profile's budget covers a full worst-case start attempt") {
        // The failure mode this is sized against: one slow CoreAudio open eats
        // the whole budget, so the retry that would have succeeded never runs.
        // A single attempt fences three sequential stages — route selection,
        // format snapshot, engine start — so the budget has to cover all
        // three, for the background plan exactly as it already does for the
        // foreground one.
        let profiles = [
            DictationStartReadinessPolicy.profile(triggerRawValue: "menu", isAppActive: true),
            DictationStartReadinessPolicy.profile(triggerRawValue: "physical_key", isAppActive: false),
        ]
        for profile in profiles {
            let fenceNanoseconds = max(
                profile.audioStartOperationTimeoutNanoseconds,
                profile.systemInputOperationTimeoutNanoseconds
            )
            let fenceSeconds = Double(fenceNanoseconds) / 1_000_000_000
            assertTrue(
                profile.recoveryBudget >= fenceSeconds * 3,
                "\(profile.name): three sequential fences must fit inside the budget"
            )
            assertTrue(
                profile.recoveryBudget > TranscriptedConstants.dictationReadinessRefreshTimeout,
                "\(profile.name): a single stale readiness refresh must not consume the budget"
            )
        }
    }

    runSuite("Readiness refreshes keep the foreground fences") {
        // `refreshInputReadiness` goes through prewarm, which never sets the
        // start fences, so `dictationReadinessRefreshTimeout` still outlasts
        // one refresh exactly as `DictationInputBindingSettleTests` pins it.
        // Widening the start fences must not quietly invalidate that.
        assertTrue(
            TranscriptedConstants.dictationReadinessRefreshTimeout > Double(
                TranscriptedConstants.systemInputOperationTimeout
                    + TranscriptedConstants.audioStartOperationTimeout
                    + TranscriptedConstants.audioInputBindingSettleTimeout
            ) / 1_000_000_000,
            "the refresh budget is sized against the foreground fences, not the background ones"
        )
    }

    runSuite("App Nap suppression is reference counted and balanced") {
        let recorder = ActivityRecorder()
        let activity = DictationProcessActivity(
            begin: { options, reason in recorder.begin(options: options, reason: reason) },
            end: { token in recorder.end(token) }
        )

        assertFalse(activity.isHeld, "nothing is asserted before a session starts")

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
