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
