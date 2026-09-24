import Foundation

func testMeetingPromptPriority() {
    runSuite("Unverified system audio stays honest until this recording receives signal") {
        let waiting = MeetingSystemAudioDegradationPolicy.reconcilingSignalVerification(
            current: nil, signalVerified: false, shouldWarn: false, isRecording: true)
        assertEqual(waiting, nil, "a verified preflight may have a short observation grace period")
        let warning = MeetingSystemAudioDegradationPolicy.reconcilingSignalVerification(
            current: nil, signalVerified: false, shouldWarn: true, isRecording: true)
        assertEqual(warning?.cause, .unverified, "no signal is uncertainty, never fabricated denial")
        assertEqual(warning?.shouldPresentPrompt, true, "never-verified recording needs visible notice")
        assertEqual(warning?.degradesSavedCapture, false, "quiet is not failure")
        assertEqual(MeetingPromptPriority.resolve(inactivity: nil, systemAudio: warning, routeActive: false,
            micBoostVisible: false, current: nil, isRecording: true), .systemAudio, "notice reaches the actual prompt resolver")
        let dismissed = warning?.dismissingPrompt()
        let stillSilent = MeetingSystemAudioDegradationPolicy.next(current: dismissed, status: .silent, isRecording: true)
        let stillHealthy = MeetingSystemAudioDegradationPolicy.next(current: stillSilent, status: .healthy, isRecording: true)
        let checkedAgain = MeetingSystemAudioDegradationPolicy.reconcilingSignalVerification(
            current: stillHealthy, signalVerified: false, shouldWarn: true, isRecording: true)
        assertEqual(checkedAgain?.cause, .unverified, "acknowledgement and healthy buffer delivery are not signal proof")
        assertEqual(checkedAgain?.shouldPresentPrompt, false, "do not nag after acknowledgement")
        let verified = MeetingSystemAudioDegradationPolicy.reconcilingSignalVerification(
            current: checkedAgain, signalVerified: true, shouldWarn: true, isRecording: true)
        assertEqual(verified, nil, "actual signal clears the notice")
        let ordinarySilence = MeetingSystemAudioDegradationPolicy.next(current: verified, status: .silent, isRecording: true)
        let checkedSilence = MeetingSystemAudioDegradationPolicy.reconcilingSignalVerification(
            current: ordinarySilence, signalVerified: true, shouldWarn: true, isRecording: true)
        assertEqual(checkedSilence?.cause, .silence, "later quiet remains normal silence")
        assertEqual(checkedSilence?.shouldPresentPrompt, false, "no repeated playback check after signal")
        assertEqual(checkedSilence?.degradesSavedCapture, false, "normal quiet remains healthy")
        assertEqual(MeetingSystemAudioDegradationPolicy.reconcilingSignalVerification(
            current: warning, signalVerified: false, shouldWarn: true, isRecording: false), nil,
            "late callbacks after stop cannot restore a notice")
        let failed = MeetingSystemAudioDegradationPolicy.next(current: warning, status: .failed, isRecording: true)
        let failedAndVerified = MeetingSystemAudioDegradationPolicy.reconcilingSignalVerification(
            current: failed, signalVerified: true, shouldWarn: true, isRecording: true)
        assertEqual(failedAndVerified?.cause, .failure, "signal does not conceal an actual capture failure")
        assertEqual(failedAndVerified?.degradesSavedCapture, true, "real failures still degrade saved capture")
    }
    runSuite("A call the tap can't hear gets its own warning and degrades the saved meeting") {
        let unverified = MeetingSystemAudioDegradationPolicy.reconcilingSignalVerification(
            current: nil, signalVerified: false, shouldWarn: true, isRecording: true)
        let unheard = MeetingSystemAudioDegradationPolicy.reconcilingUnheardPlayback(
            current: unverified, notHearingPlayback: true, isRecording: true)
        assertEqual(unheard?.cause, .unheardPlayback, "hearing nothing while a call plays is sharper than unverified")
        assertEqual(unheard?.shouldPresentPrompt, true, "the user is told during the meeting")
        assertEqual(unheard?.degradesSavedCapture, true, "the other side was probably lost")
        assertEqual(MeetingSystemAudioDegradationCopy.title(for: unheard!), "Can't hear the call")
        assertFalse(MeetingSystemAudioDegradationCopy.detail(for: unheard!).contains("—"), "no em dashes in product copy")

        let dismissed = unheard?.dismissingPrompt()
        let stillUnheard = MeetingSystemAudioDegradationPolicy.reconcilingUnheardPlayback(
            current: dismissed, notHearingPlayback: true, isRecording: true)
        assertEqual(stillUnheard?.isPromptDismissed, true, "an acknowledged warning does not come back every tick")

        let quietTick = MeetingSystemAudioDegradationPolicy.next(current: stillUnheard, status: .silent, isRecording: true)
        let healthyTick = MeetingSystemAudioDegradationPolicy.next(current: quietTick, status: .healthy, isRecording: true)
        assertEqual(healthyTick?.cause, .unheardPlayback, "level status flips do not clear it")
        assertEqual(healthyTick?.phase, .degraded, "buffers flowing is not the call being heard")

        let quietCall = MeetingSystemAudioDegradationPolicy.reconcilingUnheardPlayback(
            current: healthyTick, notHearingPlayback: false, isRecording: true)
        assertEqual(quietCall, nil, "signal on the same tap means the call was just quiet: no warning, nothing degraded")

        let back = MeetingSystemAudioDegradationPolicy.reconcilingUnheardPlayback(
            current: healthyTick, notHearingPlayback: false, playbackLossConfirmed: true, isRecording: true)
        assertEqual(back?.phase, .recovered, "signal that needed a new tap or output moves the warning to recovered")
        assertEqual(back?.degradesSavedCapture, true, "the gap stays on the saved meeting")
        assertEqual(MeetingSystemAudioDegradationCopy.title(for: back!), "Call audio is back")
        let verifiedLater = MeetingSystemAudioDegradationPolicy.reconcilingSignalVerification(
            current: back, signalVerified: true, shouldWarn: true, isRecording: true)
        assertEqual(verifiedLater, back, "signal verification does not erase the recovered loss")

        let again = MeetingSystemAudioDegradationPolicy.reconcilingUnheardPlayback(
            current: back, notHearingPlayback: true, isRecording: true)
        assertEqual(again?.phase, .degraded, "losing the call a second time warns again")
        assertEqual(again?.isPromptDismissed, false)
    }

    runSuite("A call-audio-is-back notice only informs and hides itself") {
        let interrupted = MeetingSystemAudioDegradationPolicy.next(current: nil, status: .reconnecting, isRecording: true)!
        assertTrue(MeetingSystemAudioPromptPolicy.offersActions(for: interrupted), "an active loss keeps its buttons")
        assertEqual(MeetingSystemAudioPromptPolicy.autoHideSeconds(for: interrupted), nil, "an active loss waits for the user")

        let reconnected = MeetingSystemAudioDegradationPolicy.next(current: interrupted, status: .healthy, isRecording: true)!
        assertEqual(reconnected.phase, .recovered)
        assertFalse(MeetingSystemAudioPromptPolicy.offersActions(for: reconnected), "good news has nothing to decide")
        assertEqual(MeetingSystemAudioPromptPolicy.autoHideSeconds(for: reconnected), 4, "it goes away on its own")
        assertEqual(MeetingSystemAudioDegradationCopy.detail(for: reconnected), "A few seconds of call audio may be missing.")

        let hidden = reconnected.dismissingPrompt()
        assertFalse(hidden.shouldPresentPrompt, "hiding it is an acknowledgement")
        assertTrue(hidden.degradesSavedCapture, "the saved meeting still keeps the gap")

        let unheard = MeetingSystemAudioDegradationPolicy.reconcilingUnheardPlayback(
            current: nil, notHearingPlayback: true, isRecording: true)!
        let back = MeetingSystemAudioDegradationPolicy.reconcilingUnheardPlayback(
            current: unheard, notHearingPlayback: false, playbackLossConfirmed: true, isRecording: true)!
        assertEqual(MeetingSystemAudioPromptPolicy.autoHideSeconds(for: back), 4)
        assertEqual(MeetingSystemAudioDegradationCopy.detail(for: back), "Some call audio may be missing.")

        let failed = MeetingSystemAudioDegradationPolicy.next(current: nil, status: .failed, isRecording: true)!
        let interruptedDegraded = MeetingSystemAudioDegradationWarning(
            cause: .interruption, phase: .degraded, isPromptDismissed: false, observedNonSilenceCause: true)
        for warning in [interrupted, reconnected, unheard, back, failed, interruptedDegraded] {
            let copy = MeetingSystemAudioDegradationCopy.accessibilityLabel(for: warning)
            assertFalse(copy.contains("degraded"), "no internal words in the prompt: \(copy)")
        }
    }

    runSuite("A quiet-call false alarm never undoes an earlier real interruption") {
        let interrupted = MeetingSystemAudioDegradationPolicy.next(current: nil, status: .reconnecting, isRecording: true)
        let recovered = MeetingSystemAudioDegradationPolicy.next(current: interrupted, status: .healthy, isRecording: true)
        let unheard = MeetingSystemAudioDegradationPolicy.reconcilingUnheardPlayback(
            current: recovered, notHearingPlayback: true, isRecording: true)
        assertEqual(unheard?.cause, .unheardPlayback)
        let quiet = MeetingSystemAudioDegradationPolicy.reconcilingUnheardPlayback(
            current: unheard, notHearingPlayback: false, isRecording: true)
        assertEqual(quiet?.degradesSavedCapture, true, "the earlier interruption still marks the meeting degraded")

        let fresh = MeetingSystemAudioDegradationPolicy.reconcilingUnheardPlayback(
            current: nil, notHearingPlayback: true, isRecording: true)
        assertEqual(fresh?.observedNonSilenceCause, false, "nothing before the notice degraded this meeting")
    }

    runSuite("Unheard playback never hides a real interruption or failure") {
        let reconnecting = MeetingSystemAudioDegradationPolicy.next(current: nil, status: .reconnecting, isRecording: true)
        assertEqual(MeetingSystemAudioDegradationPolicy.reconcilingUnheardPlayback(
            current: reconnecting, notHearingPlayback: true, isRecording: true)?.cause, .interruption)
        let failed = MeetingSystemAudioDegradationPolicy.next(current: nil, status: .failed, isRecording: true)
        assertEqual(MeetingSystemAudioDegradationPolicy.reconcilingUnheardPlayback(
            current: failed, notHearingPlayback: true, isRecording: true)?.cause, .failure)
        let silence = MeetingSystemAudioDegradationPolicy.next(current: nil, status: .silent, isRecording: true)
        assertEqual(MeetingSystemAudioDegradationPolicy.reconcilingUnheardPlayback(
            current: silence, notHearingPlayback: true, isRecording: true)?.cause, .unheardPlayback,
            "plain silence gives way to the sharper warning")
        assertEqual(MeetingSystemAudioDegradationPolicy.reconcilingUnheardPlayback(
            current: nil, notHearingPlayback: false, isRecording: true), nil, "nothing to say when the tap is fine")
        assertEqual(MeetingSystemAudioDegradationPolicy.reconcilingUnheardPlayback(
            current: nil, notHearingPlayback: true, isRecording: false), nil, "no warnings after stop")
    }

    runSuite("MeetingSystemAudioDegradationPolicy remembers an interruption across later silence") {
        // `cause` is overwritten on every transition, so the saved-capture
        // degraded stamp must key off whether a non-silence cause was ever
        // observed, not off the latest cause.
        let interrupted = MeetingSystemAudioDegradationPolicy.next(current: nil, status: .reconnecting, isRecording: true)
        let recovered = MeetingSystemAudioDegradationPolicy.next(current: interrupted, status: .healthy, isRecording: true)
        let thenSilent = MeetingSystemAudioDegradationPolicy.next(current: recovered, status: .silent, isRecording: true)
        let silentThenHealthy = MeetingSystemAudioDegradationPolicy.next(current: thenSilent, status: .healthy, isRecording: true)

        assertEqual(interrupted?.degradesSavedCapture, true, "an interruption degrades the saved capture")
        assertEqual(recovered?.degradesSavedCapture, true, "recovery does not erase the earlier interruption")
        assertEqual(thenSilent?.cause, .silence, "the latest cause is silence")
        assertEqual(thenSilent?.degradesSavedCapture, true, "silence after an interruption must not lose the degraded stamp")
        assertEqual(silentThenHealthy?.degradesSavedCapture, true, "nor may a later recovery")

        let silentOnly = MeetingSystemAudioDegradationPolicy.next(current: nil, status: .silent, isRecording: true)
        let silentRecovered = MeetingSystemAudioDegradationPolicy.next(current: silentOnly, status: .healthy, isRecording: true)
        assertEqual(silentOnly?.degradesSavedCapture, false, "silence alone is legitimate and must not degrade the saved capture")
        assertEqual(silentRecovered?.degradesSavedCapture, false, "recovered silence stays non-degrading")
        assertEqual(silentOnly?.dismissingPrompt().degradesSavedCapture, false, "dismissing the prompt carries the flag unchanged")

        let failed = MeetingSystemAudioDegradationPolicy.next(current: silentOnly, status: .failed, isRecording: true)
        assertEqual(failed?.degradesSavedCapture, true, "a failure after silence degrades the saved capture")
    }

    let interruption = MeetingSystemAudioDegradationWarning(
        cause: .interruption,
        phase: .recovering,
        isPromptDismissed: false
    )
    let dismissedSystemAudio = MeetingSystemAudioDegradationWarning(
        cause: .interruption,
        phase: .recovering,
        isPromptDismissed: true
    )
    let inactivity = MeetingAudioInactivityWarning(
        inactiveDuration: 5 * 60,
        countdownSeconds: 30
    )

    runSuite("MeetingPromptPriority — not recording never shows a warning prompt") {
        assertNil(
            MeetingPromptPriority.resolve(
                inactivity: inactivity,
                systemAudio: interruption,
                routeActive: true,
                micBoostVisible: true,
                current: nil,
                isRecording: false
            ),
            "every signal can be hot, but the overlay must never show a stale warning prompt once recording stops"
        )
    }

    runSuite("MeetingPromptPriority — full precedence lattice: inactivity > systemAudio > {route, micBoost}") {
        assertEqual(
            MeetingPromptPriority.resolve(
                inactivity: inactivity,
                systemAudio: interruption,
                routeActive: true,
                micBoostVisible: true,
                current: nil,
                isRecording: true
            ),
            .audioInactivity,
            "audio inactivity always wins — it can auto-stop the recording"
        )
        assertEqual(
            MeetingPromptPriority.resolve(
                inactivity: nil,
                systemAudio: interruption,
                routeActive: true,
                micBoostVisible: true,
                current: nil,
                isRecording: true
            ),
            .systemAudio,
            "system audio outranks route and mic boost once inactivity is clear"
        )
        assertEqual(
            MeetingPromptPriority.resolve(
                inactivity: nil,
                systemAudio: nil,
                routeActive: true,
                micBoostVisible: false,
                current: nil,
                isRecording: true
            ),
            .audioRoute,
            "route shows on its own once nothing above it is active"
        )
        assertEqual(
            MeetingPromptPriority.resolve(
                inactivity: nil,
                systemAudio: nil,
                routeActive: false,
                micBoostVisible: true,
                current: nil,
                isRecording: true
            ),
            .micBoost,
            "mic boost shows on its own once nothing above it is active"
        )
        assertNil(
            MeetingPromptPriority.resolve(
                inactivity: nil,
                systemAudio: nil,
                routeActive: false,
                micBoostVisible: false,
                current: nil,
                isRecording: true
            ),
            "no signal, no prompt"
        )
        assertNil(
            MeetingPromptPriority.resolve(
                inactivity: nil,
                systemAudio: dismissedSystemAudio,
                routeActive: false,
                micBoostVisible: false,
                current: .systemAudio,
                isRecording: true
            ),
            "a dismissed system-audio warning must not keep re-presenting"
        )
    }

    runSuite("MeetingPromptPriority — route and mic boost are mutually sticky") {
        assertEqual(
            MeetingPromptPriority.resolve(
                inactivity: nil,
                systemAudio: nil,
                routeActive: true,
                micBoostVisible: true,
                current: nil,
                isRecording: true
            ),
            .audioRoute,
            "when neither is currently shown and both fire together, route wins the tie — matching every " +
                "clear*-fallback chain in the pre-resolver code, which always re-checked route before mic boost"
        )
        assertEqual(
            MeetingPromptPriority.resolve(
                inactivity: nil,
                systemAudio: nil,
                routeActive: true,
                micBoostVisible: true,
                current: .micBoost,
                isRecording: true
            ),
            .micBoost,
            "mic boost stays up even though route also became active — a route hiccup must not steal the " +
                "prompt out from under an already-showing mic-boost offer"
        )
        assertEqual(
            MeetingPromptPriority.resolve(
                inactivity: nil,
                systemAudio: nil,
                routeActive: true,
                micBoostVisible: true,
                current: .audioRoute,
                isRecording: true
            ),
            .audioRoute,
            "route stays up even though mic boost also became active — the reverse direction of stickiness"
        )
    }

    runSuite("MeetingPromptPriority — the suppressed sibling re-applies once the sticky one clears") {
        assertEqual(
            MeetingPromptPriority.resolve(
                inactivity: nil,
                systemAudio: nil,
                routeActive: true,
                micBoostVisible: false,
                current: .micBoost,
                isRecording: true
            ),
            .audioRoute,
            "mic boost's own condition cleared while route's stayed hot — route takes over, the exact " +
                "scenario the clear*-fallback chains handled by hand before this resolver existed"
        )
        assertEqual(
            MeetingPromptPriority.resolve(
                inactivity: nil,
                systemAudio: nil,
                routeActive: false,
                micBoostVisible: true,
                current: .audioRoute,
                isRecording: true
            ),
            .micBoost,
            "route's own condition cleared while mic boost's stayed hot — mic boost takes over"
        )
    }

    runSuite("MeetingPromptPriority — recording stop clears everything, even a sticky prompt") {
        assertNil(
            MeetingPromptPriority.resolve(
                inactivity: inactivity,
                systemAudio: interruption,
                routeActive: true,
                micBoostVisible: true,
                current: .micBoost,
                isRecording: false
            ),
            "every signal still hot and a prompt still marked current, but recording stopped — nothing shows"
        )
    }
}
