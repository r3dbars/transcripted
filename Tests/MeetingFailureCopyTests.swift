import Foundation

func testMeetingFailureCopy() {
    runSuite("MeetingFailureCopy noSpeechDetected points at Try again on Home") {
        let copy = MeetingFailureCopy.make(
            forMessage: "No speech detected",
            shortErrorMessage: "No speech detected",
            isRetryable: true
        )

        assertEqual(copy.title, "No speech found", "no-speech outcomes should be named plainly")
        assertTrue(
            copy.detail.contains("kept the audio"),
            "no-speech copy should say the audio was kept"
        )
        assertTrue(
            copy.detail.contains("Home") && copy.detail.contains("Try again"),
            "saved no-speech rows now offer Try again, so the copy should say where to find it"
        )
        assertTrue(
            copy.detail.contains("If people were talking"),
            "the retry pointer is conditional, because a silent recording hides the action"
        )
        assertFalse(copy.detail.contains("\u{2014}"), "user copy avoids em dashes")
    }

    runSuite("MeetingFailureCopy noSpeechDetected keeps import and saved-audio copy") {
        // Read from the real table, so a wording change there fails here
        // instead of silently falling back to the Home retry pointer.
        let savedAudio = PipelineFailureDisplayCopy.message(for: .noSpeechDetected, flow: .savedAudioRetranscription)
        let savedCopy = MeetingFailureCopy.make(
            forMessage: savedAudio,
            shortErrorMessage: savedAudio,
            isRetryable: true
        )
        assertEqual(savedCopy.title, "No speech found", "saved-audio no-speech still reads as no speech")
        assertEqual(savedCopy.detail, savedAudio, "a saved-meeting retranscription has no Home row, so it keeps its own copy")

        let imported = PipelineFailureDisplayCopy.message(for: .noSpeechDetected, flow: .importedAudio)
        let importCopy = MeetingFailureCopy.make(
            forMessage: imported,
            shortErrorMessage: imported,
            isRetryable: true
        )
        assertEqual(importCopy.detail, imported, "an import failure keeps its own copy instead of pointing at Home")
    }

    runSuite("MeetingFailureCopy recordingTooShort says capture broke when the session ran long") {
        // TranscriptionTaskManager.recordingTooShortCaptureStoppedEarlyMessage
        let message = "Recording too short because audio capture stopped early"
        let copy = MeetingFailureCopy.make(
            forMessage: message,
            shortErrorMessage: message,
            isRetryable: false
        )
        assertEqual(copy.title, "Recording ended too soon", "it is still a too-short recording")
        assertFalse(copy.detail.contains("Nothing broke"), "capture did break here, so the copy must not say otherwise")
        assertTrue(copy.detail.contains("stopped early"), "the copy should say capture stopped early")
        assertFalse(copy.detail.contains("\u{2014}"), "user copy avoids em dashes")

        let plain = MeetingFailureCopy.make(
            forMessage: "Recording too short",
            shortErrorMessage: "Recording too short",
            isRetryable: false
        )
        assertTrue(plain.detail.contains("Nothing broke"), "a plain too-short recording keeps its old copy")
    }
}
