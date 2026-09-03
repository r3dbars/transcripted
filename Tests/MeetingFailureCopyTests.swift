import Foundation

func testMeetingFailureCopy() {
    runSuite("MeetingFailureCopy noSpeechDetected does not promise a retry") {
        let copy = MeetingFailureCopy.make(
            forMessage: "No speech detected",
            shortErrorMessage: "No speech detected",
            isRetryable: false
        )

        assertEqual(copy.title, "No speech found", "no-speech outcomes should be named plainly")
        assertFalse(
            copy.detail.lowercased().contains("retry"),
            "no-speech copy must not promise a retry Home cannot offer"
        )
        assertTrue(
            copy.detail.contains("audio was kept"),
            "no-speech copy should say the audio was kept"
        )
        assertTrue(
            copy.detail.contains("clearer voices"),
            "no-speech copy should tell the user to record again with clearer voices"
        )
    }
}
