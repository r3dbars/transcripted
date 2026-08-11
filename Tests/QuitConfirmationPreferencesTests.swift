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
            "Meeting work is still running",
            "alert title should cover recording and background transcription work"
        )
        assertTrue(
            presentation.message.contains("Keep Transcripted open"),
            "alert should offer the safe path of keeping the app open"
        )
        assertTrue(
            presentation.message.contains("save the audio and quit"),
            "alert should explain that quit preserves retry audio"
        )
        assertEqual(
            presentation.keepRecordingTitle,
            "Keep Recording",
            "safe default button should keep recording"
        )
        assertEqual(
            presentation.stopAndTranscribeTitle,
            "Stop & Transcribe",
            "middle path should keep the app open and make a transcript"
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
