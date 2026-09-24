import Foundation

func testQuitConfirmationPreferences() {
    runSuite("ActiveMeetingQuitConfirmationPolicy prompts for active and background meeting work") {
        assertTrue(
            ActiveMeetingQuitConfirmationPolicy.shouldConfirmQuit(
                activeMeetingCapture: true
            ),
            "quit confirmation should always prompt while a meeting is recording or finishing"
        )
        assertTrue(
            ActiveMeetingQuitConfirmationPolicy.shouldConfirmQuit(
                activeMeetingCapture: false,
                backgroundTranscriptionWork: true
            ),
            "quit confirmation should also prompt while meeting transcription or imports are queued"
        )
        assertFalse(
            ActiveMeetingQuitConfirmationPolicy.shouldConfirmQuit(
                activeMeetingCapture: false
            ),
            "idle quits should not show an extra dialog"
        )
    }

    runSuite("ActiveMeetingQuitConfirmationPolicy copy explains the consequence") {
        let presentation = ActiveMeetingQuitConfirmationPolicy.presentation

        assertEqual(
            presentation.title,
            "A meeting is still recording",
            "alert title should say plainly that a live recording is running"
        )
        assertTrue(
            presentation.message.contains("Transcripted stays open"),
            "alert should say Stop Recording keeps the app open instead of quitting"
        )
        assertTrue(
            presentation.message.contains("Meetings page"),
            "alert should point at the Meetings page, the sidebar's real name"
        )
        assertFalse(
            presentation.message.contains("Home"),
            "alert should not name a Home page the sidebar doesn't have"
        )
        assertFalse(
            ActiveMeetingQuitConfirmationPolicy.backgroundPresentation.message.contains("Home"),
            "background alert should not name a Home page the sidebar doesn't have"
        )
        assertEqual(
            presentation.keepRecordingTitle,
            "Keep Recording",
            "safe default button should keep recording"
        )
        assertEqual(
            presentation.stopAndTranscribeTitle,
            "Stop Recording",
            "middle path stops the meeting and keeps the app open, so it should not read like a quit"
        )
        assertEqual(
            presentation.saveAudioAndQuitTitle,
            "Save Audio & Quit",
            "confirm button should describe the recoverable quit path"
        )

        let backgroundPresentation = ActiveMeetingQuitConfirmationPolicy.backgroundPresentation
        assertEqual(
            backgroundPresentation.title,
            "Meeting transcript is still running",
            "background-only alert should name transcript work instead of active recording"
        )
        assertEqual(
            backgroundPresentation.keepOpenTitle,
            "Keep Open",
            "background-only alert should not offer a recording action"
        )
        assertEqual(
            backgroundPresentation.saveAudioAndQuitTitle,
            "Save Audio & Quit",
            "background-only quit should still describe preserved audio"
        )
    }
}
