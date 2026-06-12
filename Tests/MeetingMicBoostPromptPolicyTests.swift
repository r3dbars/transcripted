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
