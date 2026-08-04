import Foundation

func testMeetingPromptPriority() {
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
