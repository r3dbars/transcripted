import Foundation

func testFailedMeetingPresentation() {
    runSuite("FailedMeetingPresentation short audio failures get actionable copy") {
        let copy = MeetingFailureCopy.make(
            forMessage: "Invalid audio data provided. Must be at least 1 second of 16kHz audio.",
            shortErrorMessage: "Invalid audio data provided. Must be at least 1 second of 16kHz audio.",
            isRetryable: false
        )

        assertEqual(copy.title, "Recording was too short", "short captures should stop looking like generic retries")
        assertEqual(
            copy.detail,
            "Transcripted needs at least a second of audio. Keep the meeting running a little longer, then retry.",
            "short captures should explain how to avoid the failure next time"
        )
    }

    runSuite("FailedMeetingPresentation screen recording failures point to settings") {
        let copy = MeetingFailureCopy.make(
            forMessage: "System audio is required. Turn on Screen Recording and retry.",
            shortErrorMessage: "System audio is required. Turn on Screen Recording and retry.",
            isRetryable: false
        )

        assertEqual(copy.title, "Turn on Screen Recording", "permission failures should name the missing permission")
        assertEqual(
            copy.detail,
            "Turn on Screen Recording in System Settings, then retry the meeting.",
            "permission failures should point to the recovery step"
        )
    }
}
