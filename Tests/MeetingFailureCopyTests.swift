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
        let savedAudio = "No speech was found in that saved audio. Try a recording with clearer spoken audio."
        let savedCopy = MeetingFailureCopy.make(
            forMessage: savedAudio,
            shortErrorMessage: savedAudio,
            isRetryable: true
        )
        assertEqual(savedCopy.title, "No speech found", "saved-audio no-speech still reads as no speech")
        assertEqual(savedCopy.detail, savedAudio, "a saved-meeting retranscription has no Home row, so it keeps its own copy")

        let imported = "No speech was found in that audio file. Choose a file with clear spoken audio and try again."
        let importCopy = MeetingFailureCopy.make(
            forMessage: imported,
            shortErrorMessage: imported,
            isRetryable: true
        )
        assertEqual(importCopy.detail, imported, "an import failure keeps its own copy instead of pointing at Home")
    }
}
