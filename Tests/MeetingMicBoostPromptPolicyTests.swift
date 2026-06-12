import Foundation

func testMeetingMicBoostPromptPolicy() {
    runSuite("MeetingMicBoostPromptPolicy.shouldPresent — presents only for fresh recordings with the preference off") {
        assertTrue(
            MeetingMicBoostPromptPolicy.shouldPresent(
                isRecording: true,
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
                voiceProcessingPreferenceEnabled: false,
                currentOutcome: .shown
            ),
            "a prompt already on screen should not be re-presented"
        )
        assertFalse(
            MeetingMicBoostPromptPolicy.shouldPresent(
                isRecording: true,
                voiceProcessingPreferenceEnabled: false,
                currentOutcome: .accepted
            ),
            "an accepted boost should never re-prompt during the same recording"
        )
        assertFalse(
            MeetingMicBoostPromptPolicy.shouldPresent(
                isRecording: true,
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
                voiceProcessingPreferenceEnabled: false,
                currentOutcome: .notShown
            ),
            "a late cue after stop should not surface a prompt"
        )
    }

    runSuite("MeetingMicBoostPromptPolicy.shouldPresent — blocked while stop is in flight") {
        assertFalse(
            MeetingMicBoostPromptPolicy.shouldPresent(
                isRecording: true,
                isStopping: true,
                voiceProcessingPreferenceEnabled: false,
                currentOutcome: .notShown
            ),
            "a cue racing stop cleanup should not surface a stale prompt"
        )
    }

    runSuite("MeetingMicBoostPromptPolicy.shouldApplyAction — action is live-recording only") {
        assertTrue(
            MeetingMicBoostPromptPolicy.shouldApplyAction(
                isPromptVisible: true,
                isRecording: true,
                isStopping: false
            ),
            "visible prompts may apply while the recording is still active"
        )
        assertFalse(
            MeetingMicBoostPromptPolicy.shouldApplyAction(
                isPromptVisible: false,
                isRecording: true,
                isStopping: false
            ),
            "hidden prompts should not act"
        )
        assertFalse(
            MeetingMicBoostPromptPolicy.shouldApplyAction(
                isPromptVisible: true,
                isRecording: false,
                isStopping: false
            ),
            "stale UI actions after stop should not act"
        )
        assertFalse(
            MeetingMicBoostPromptPolicy.shouldApplyAction(
                isPromptVisible: true,
                isRecording: true,
                isStopping: true
            ),
            "stale UI actions during stop cleanup should not act"
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
