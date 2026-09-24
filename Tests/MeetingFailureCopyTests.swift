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
}
