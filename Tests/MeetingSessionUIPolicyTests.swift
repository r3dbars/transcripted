import Foundation

func testMeetingSessionUIPolicy() {
    runSuite("MeetingSessionUIPolicy.shouldShowTranscribing — ignores speaker review without real pipeline work") {
        assertFalse(
            MeetingSessionUIPolicy.shouldShowTranscribing(
                activeTranscriptions: 0,
                queuedTranscriptions: 0
            ),
            "speaker review alone should not keep the meeting overlay in the saving state"
        )
    }

    runSuite("MeetingSessionUIPolicy.shouldShowTranscribing — stays active while a transcription is running") {
        assertTrue(
            MeetingSessionUIPolicy.shouldShowTranscribing(
                activeTranscriptions: 1,
                queuedTranscriptions: 0
            ),
            "an active transcription should keep the saving state visible"
        )
    }

    runSuite("MeetingSessionUIPolicy.shouldShowTranscribing — stays active while work is queued") {
        assertTrue(
            MeetingSessionUIPolicy.shouldShowTranscribing(
                activeTranscriptions: 0,
                queuedTranscriptions: 1
            ),
            "queued meeting work should keep the saving state visible until it starts"
        )
    }

    runSuite("MeetingSessionUIPolicy.canStartQueuedTranscription — waits while speaker review is pending") {
        assertFalse(
            MeetingSessionUIPolicy.canStartQueuedTranscription(
                activeTranscriptions: 0,
                isSpeakerReviewPending: true,
                isPreparingQueuedTranscriptionStart: false
            ),
            "speaker review should keep the next queued transcription from starting until the transcript is finalized"
        )
    }

    runSuite("MeetingSessionUIPolicy.canStartQueuedTranscription — starts once speaker review clears") {
        assertTrue(
            MeetingSessionUIPolicy.canStartQueuedTranscription(
                activeTranscriptions: 0,
                isSpeakerReviewPending: false,
                isPreparingQueuedTranscriptionStart: false
            ),
            "a queued meeting should start as soon as the old speaker review publishes nil"
        )
    }

    runSuite("MeetingSessionUIPolicy.canStartQueuedTranscription — blocks duplicate starts") {
        assertFalse(
            MeetingSessionUIPolicy.canStartQueuedTranscription(
                activeTranscriptions: 1,
                isSpeakerReviewPending: false,
                isPreparingQueuedTranscriptionStart: false
            ),
            "active transcription work should remain single-flight"
        )
        assertFalse(
            MeetingSessionUIPolicy.canStartQueuedTranscription(
                activeTranscriptions: 0,
                isSpeakerReviewPending: false,
                isPreparingQueuedTranscriptionStart: true
            ),
            "a queued start already being prepared should not be started twice"
        )
    }

    runSuite("MeetingSessionUIPolicy.shouldClearTranscriptionTriggerWhenIdle — keeps trigger through speaker review") {
        assertFalse(
            MeetingSessionUIPolicy.shouldClearTranscriptionTriggerWhenIdle(
                isSpeakerReviewPending: true
            ),
            "speaker review can publish the terminal saved or failed status after active transcription work clears"
        )

        assertTrue(
            MeetingSessionUIPolicy.shouldClearTranscriptionTriggerWhenIdle(
                isSpeakerReviewPending: false
            ),
            "completed work without speaker review should clear the last start trigger"
        )
    }

    runSuite("MeetingRecordingTitlePolicy — explicit prompt title wins over calendar fallback") {
        assertEqual(
            MeetingRecordingTitlePolicy.resolve(
                explicitTitle: "Prompt Title",
                calendarTitle: "Calendar Title"
            ),
            "Prompt Title",
            "explicit prompt context should not be overwritten by a later calendar lookup"
        )
    }

    runSuite("MeetingRecordingTitlePolicy — manual starts can use the calendar title") {
        assertEqual(
            MeetingRecordingTitlePolicy.resolve(
                explicitTitle: nil,
                calendarTitle: "Transcripted Calendar Smoke Live"
            ),
            "Transcripted Calendar Smoke Live",
            "manual, menu, and hotkey starts should still get the active calendar event title"
        )
    }

    runSuite("MeetingRecordingTitlePolicy — blank titles are ignored") {
        assertEqual(
            MeetingRecordingTitlePolicy.resolve(
                explicitTitle: " \n ",
                calendarTitle: "Calendar Title"
            ),
            "Calendar Title",
            "blank prompt titles should not block the calendar fallback"
        )
        assertNil(
            MeetingRecordingTitlePolicy.resolve(
                explicitTitle: nil,
                calendarTitle: " \r\n "
            ),
            "blank calendar titles should not become transcript titles"
        )
    }
}
