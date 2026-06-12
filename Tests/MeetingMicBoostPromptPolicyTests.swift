import Foundation

// Invariant under test: the mic-boost prompt flag is never true while nothing
// is recording, and no prompt action may persist state for a dead recording.

func testMeetingMicBoostPromptPolicy() {
    runSuite("MeetingMicBoostPromptPolicy.shouldPresent — presents only for fresh recordings with the preference off") {
        assertTrue(
            MeetingMicBoostPromptPolicy.shouldPresent(
                isRecording: true,
                isFinishingRecording: false,
                sessionStateIsRecording: true,
                voiceProcessingPreferenceEnabled: false,
                currentOutcome: .notShown
            ),
            "a live recording with VPIO off and no prior prompt should be offered the boost"
        )
    }

    runSuite("MeetingMicBoostPromptPolicy.shouldPresent — never prompts users who already enabled voice processing") {
        assertFalse(
            MeetingMicBoostPromptPolicy.shouldPresent(
                isRecording: true,
                isFinishingRecording: false,
                sessionStateIsRecording: true,
                voiceProcessingPreferenceEnabled: true,
                currentOutcome: .notShown
            ),
            "already-fixed users (preference on) should never see the prompt"
        )
    }

    runSuite("MeetingMicBoostPromptPolicy.shouldPresent — one-shot latch blocks every non-fresh outcome") {
        assertFalse(
            MeetingMicBoostPromptPolicy.shouldPresent(
                isRecording: true,
                isFinishingRecording: false,
                sessionStateIsRecording: true,
                voiceProcessingPreferenceEnabled: false,
                currentOutcome: .shown
            ),
            "a prompt already on screen should not be re-presented"
        )
        assertFalse(
            MeetingMicBoostPromptPolicy.shouldPresent(
                isRecording: true,
                isFinishingRecording: false,
                sessionStateIsRecording: true,
                voiceProcessingPreferenceEnabled: false,
                currentOutcome: .accepted
            ),
            "an accepted boost should never re-prompt during the same recording"
        )
        assertFalse(
            MeetingMicBoostPromptPolicy.shouldPresent(
                isRecording: true,
                isFinishingRecording: false,
                sessionStateIsRecording: true,
                voiceProcessingPreferenceEnabled: false,
                currentOutcome: .declined
            ),
            "declining must latch for the rest of the recording — never ask again"
        )
    }

    runSuite("MeetingMicBoostPromptPolicy.shouldPresent — blocked when not recording") {
        assertFalse(
            MeetingMicBoostPromptPolicy.shouldPresent(
                isRecording: false,
                isFinishingRecording: false,
                sessionStateIsRecording: false,
                voiceProcessingPreferenceEnabled: false,
                currentOutcome: .notShown
            ),
            "a late cue after stop should not surface a prompt"
        )
    }

    runSuite("MeetingMicBoostPromptPolicy.shouldPresent — the prompt flag is never re-latched mid-stop") {
        assertFalse(
            MeetingMicBoostPromptPolicy.shouldPresent(
                isRecording: true,
                isFinishingRecording: true,
                sessionStateIsRecording: true,
                voiceProcessingPreferenceEnabled: false,
                currentOutcome: .notShown
            ),
            "a cue landing while stop/cancel/termination teardown awaits capture files must not re-latch the prompt the stop path already cleared"
        )
        assertFalse(
            MeetingMicBoostPromptPolicy.shouldPresent(
                isRecording: true,
                isFinishingRecording: false,
                sessionStateIsRecording: false,
                voiceProcessingPreferenceEnabled: false,
                currentOutcome: .notShown
            ),
            "a cue landing after the session state machine left .recording must not surface a prompt even if the capture flag has not settled yet"
        )
    }

    runSuite("MeetingMicBoostPromptPolicy.shouldApplyPromptAction — stale actions never persist for a dead recording") {
        assertTrue(
            MeetingMicBoostPromptPolicy.shouldApplyPromptAction(
                isPromptVisible: true,
                isRecording: true,
                isFinishingRecording: false,
                sessionStateIsRecording: true
            ),
            "actioning a visible prompt during a live recording applies normally"
        )
        assertFalse(
            MeetingMicBoostPromptPolicy.shouldApplyPromptAction(
                isPromptVisible: true,
                isRecording: false,
                isFinishingRecording: false,
                sessionStateIsRecording: false
            ),
            "a stale accept after capture stopped must not flip the global VPIO preference or record an outcome"
        )
        assertFalse(
            MeetingMicBoostPromptPolicy.shouldApplyPromptAction(
                isPromptVisible: false,
                isRecording: true,
                isFinishingRecording: false,
                sessionStateIsRecording: true
            ),
            "an action with no visible prompt stays a no-op"
        )
        assertFalse(
            MeetingMicBoostPromptPolicy.shouldApplyPromptAction(
                isPromptVisible: true,
                isRecording: true,
                isFinishingRecording: true,
                sessionStateIsRecording: true
            ),
            "stale UI actions during stop cleanup should not act"
        )
        assertFalse(
            MeetingMicBoostPromptPolicy.shouldApplyPromptAction(
                isPromptVisible: true,
                isRecording: true,
                isFinishingRecording: false,
                sessionStateIsRecording: false
            ),
            "stale UI actions after state left recording should not act"
        )
    }

    runSuite("MeetingMicBoostPromptOutcome — rawValues are a persisted frontmatter contract") {
        assertEqual(
            MeetingMicBoostPromptOutcome.notShown.rawValue,
            "not_shown",
            "not_shown is persisted in transcript frontmatter; do not rename"
        )
        assertEqual(
            MeetingMicBoostPromptOutcome.shown.rawValue,
            "shown",
            "shown is persisted in transcript frontmatter; do not rename"
        )
        assertEqual(
            MeetingMicBoostPromptOutcome.accepted.rawValue,
            "accepted",
            "the Home scanner reads the literal 'accepted'; do not rename"
        )
        assertEqual(
            MeetingMicBoostPromptOutcome.declined.rawValue,
            "declined",
            "declined is persisted in transcript frontmatter; do not rename"
        )
    }
}
