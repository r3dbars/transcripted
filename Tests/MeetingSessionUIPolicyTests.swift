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

    runSuite("MeetingSessionUIPolicy.canStartQueuedTranscription — speaker review does not block next meeting") {
        assertTrue(
            MeetingSessionUIPolicy.canStartQueuedTranscription(
                activeTranscriptions: 0,
                isPreparingQueuedTranscriptionStart: false
            ),
            "speaker review should stay open while the next queued meeting starts"
        )
    }

    runSuite("MeetingSessionUIPolicy.canStartQueuedTranscription — starts when no pipeline is active") {
        assertTrue(
            MeetingSessionUIPolicy.canStartQueuedTranscription(
                activeTranscriptions: 0,
                isPreparingQueuedTranscriptionStart: false
            ),
            "a queued meeting should start as soon as prior transcription work clears"
        )
    }

    runSuite("MeetingSessionUIPolicy.canStartQueuedTranscription — blocks duplicate starts") {
        assertFalse(
            MeetingSessionUIPolicy.canStartQueuedTranscription(
                activeTranscriptions: 1,
                isPreparingQueuedTranscriptionStart: false
            ),
            "active transcription work should remain single-flight"
        )
        assertFalse(
            MeetingSessionUIPolicy.canStartQueuedTranscription(
                activeTranscriptions: 0,
                isPreparingQueuedTranscriptionStart: true
            ),
            "a queued start already being prepared should not be started twice"
        )
    }

    runSuite("MeetingSessionUIPolicy.shouldClearTranscriptionTriggerAfterBackgroundWork — waits for terminal status") {
        assertFalse(
            MeetingSessionUIPolicy.shouldClearTranscriptionTriggerAfterBackgroundWork(
                hasTerminalOutcome: false
            ),
            "the trigger should survive if active work clears before the saved/failed status arrives"
        )
        assertTrue(
            MeetingSessionUIPolicy.shouldClearTranscriptionTriggerAfterBackgroundWork(
                hasTerminalOutcome: true
            ),
            "the trigger can clear once terminal telemetry has a status to report"
        )
        assertFalse(
            MeetingSessionUIPolicy.shouldClearTranscriptionTriggerAfterBackgroundWork(
                hasTerminalOutcome: true,
                hasSpeakerReviewWork: true
            ),
            "saved meeting trigger attribution should survive until speaker review finalization reports its own outcome"
        )
    }

    runSuite("MeetingRecordingTitlePolicy — nil titles stay nil") {
        assertNil(
            MeetingRecordingTitlePolicy.resolve(
                explicitTitle: nil,
                calendarTitle: nil
            ),
            "untitled manual starts should stay untitled instead of inventing metadata"
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

    runSuite("MeetingRecordingTitlePolicy — multiline titles normalize before save") {
        assertEqual(
            MeetingRecordingTitlePolicy.normalized("  Product sync\r\nFollow-up  "),
            "Product sync  Follow-up",
            "transcript titles should be single-line and trimmed before persistence"
        )
    }
}
