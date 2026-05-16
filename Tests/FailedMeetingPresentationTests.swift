import Foundation

func testFailedMeetingPresentation() {
    runSuite("FailedMeetingPresentation short audio failures get actionable copy") {
        let copy = MeetingFailureCopy.make(
            forMessage: "Invalid audio data provided. Must be at least 1 second of 16kHz audio.",
            shortErrorMessage: "Invalid audio data provided. Must be at least 1 second of 16kHz audio.",
            isRetryable: false
        )

        assertEqual(copy.title, "Recording ended too soon", "short captures should stop looking like generic retries")
        assertEqual(
            copy.detail,
            "Nothing broke - there just was not enough audio to transcribe. Record at least two seconds before stopping.",
            "short captures should explain the intentional terminal outcome"
        )
    }

    runSuite("FailedMeetingPresentation does not classify unrelated minimum-copy as short audio") {
        let copy = MeetingFailureCopy.make(
            forMessage: "Upload failed after at least one retry because the destination was unavailable.",
            shortErrorMessage: "Upload failed after at least one retry.",
            isRetryable: true
        )

        assertEqual(copy.title, "Transcript needs another pass", "generic retry copy should not look like short audio")
        assertEqual(copy.detail, "Upload failed after at least one retry.", "generic retry detail should be preserved")
    }

    runSuite("FailedMeetingPresentation system audio failures point to settings") {
        let copy = MeetingFailureCopy.make(
            forMessage: "System audio is required. Turn on System Audio Recording and retry.",
            shortErrorMessage: "System audio is required. Turn on System Audio Recording and retry.",
            isRetryable: false
        )

        assertEqual(copy.title, "Turn on System Audio Recording", "permission failures should name the missing permission")
        assertEqual(
            copy.detail,
            "Turn on System Audio Recording in System Settings, then retry the meeting.",
            "permission failures should point to the recovery step"
        )
    }

    runSuite("FailedMeetingPresentation microphone failures point to settings") {
        let copy = MeetingFailureCopy.make(
            forMessage: "Turn on Microphone access in System Settings before recording a meeting.",
            shortErrorMessage: "Turn on Microphone access in System Settings before recording a meeting.",
            isRetryable: false
        )

        assertEqual(copy.title, "Turn on Microphone", "microphone failures should name the missing permission")
        assertEqual(
            copy.detail,
            "Turn on Microphone access in System Settings, then retry the meeting.",
            "microphone failures should point to the recovery step"
        )
    }

    runSuite("FailedMeetingPresentation save failures keep the short error detail") {
        let copy = MeetingFailureCopy.make(
            forMessage: "Failed to save transcript: Could not write transcript to meetings",
            shortErrorMessage: "Could not write transcript to meetings",
            isRetryable: false
        )

        assertEqual(copy.title, "Couldn't save the transcript", "save failures should keep the save-specific title")
        assertEqual(copy.detail, "Could not write transcript to meetings", "save failures should preserve the short write error")
    }

    runSuite("FailedMeetingPresentation speaker-name failures stay speaker-specific") {
        let copy = MeetingFailureCopy.make(
            forMessage: "Speaker names could not be saved. The transcript saved, but speaker-name finalization failed.",
            shortErrorMessage: "Speaker names could not be saved.",
            isRetryable: true
        )

        assertEqual(copy.title, "Couldn't save speaker names", "speaker finalization failures should not look like full transcript failures")
        assertTrue(copy.detail.contains("transcript saved"), "copy should say the transcript itself was saved")
    }
}
