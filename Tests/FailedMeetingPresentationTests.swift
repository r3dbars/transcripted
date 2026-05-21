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

    runSuite("HomeFailedMeetingInlinePresentation shows details for non-retryable failures") {
        let presentation = HomeFailedMeetingInlinePresentation.make(
            isRetryable: false,
            isRetrying: false,
            hasAudioFiles: true,
            detail: "Turn on System Audio Recording in System Settings, then retry the meeting."
        )

        assertEqual(presentation.statusText, "Needs attention", "non-retryable rows should not ask for a retry")
        assertEqual(
            presentation.inlineDetail,
            "Turn on System Audio Recording in System Settings, then retry the meeting.",
            "the recovery detail should be visible inline instead of only in a tooltip"
        )
        assertFalse(presentation.canShowRetryAction, "non-retryable failures should not show Try again")
    }

    runSuite("HomeFailedMeetingInlinePresentation explains retryable saved audio") {
        let presentation = HomeFailedMeetingInlinePresentation.make(
            isRetryable: true,
            isRetrying: false,
            hasAudioFiles: true,
            detail: "Model was not ready."
        )

        assertEqual(presentation.statusText, "Retry ready", "retryable rows should show that recovery is available")
        assertEqual(
            presentation.inlineDetail,
            "Saved audio is still here. Try again will transcribe it.",
            "retryable rows should make saved audio preservation visible"
        )
        assertTrue(presentation.canShowRetryAction, "retryable failures with audio should show Try again")
    }

    runSuite("HomeFailedMeetingInlinePresentation blocks retries when audio is gone") {
        let presentation = HomeFailedMeetingInlinePresentation.make(
            isRetryable: true,
            isRetrying: false,
            hasAudioFiles: false,
            detail: "Model was not ready."
        )

        assertEqual(presentation.statusText, "Audio missing", "missing audio should not look like a normal retry")
        assertEqual(
            presentation.inlineDetail,
            "Saved audio is missing, so this meeting cannot be retried.",
            "missing audio should explain why Try again is unavailable"
        )
        assertFalse(presentation.canShowRetryAction, "missing audio should suppress Try again")
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

    runSuite("FailedMeetingPresentation separates retained audio from retry-ready audio") {
        let source = (try? String(
            contentsOf: repoFixtureURL("Sources/Meeting/FailedMeetingPresentation.swift"),
            encoding: .utf8
        )) ?? ""

        assertTrue(
            source.contains("let availableAudioURLs = audioURLs(for: failed)"),
            "available retained audio should stay separate from retry readiness"
        )
        assertTrue(
            source.contains("let hasRetryableAudioFiles = failed.audioFilesExist()"),
            "retry readiness should require all failed-transcription audio files"
        )
        assertTrue(
            source.contains("hasAudioFiles: hasRetryableAudioFiles"),
            "partial retained audio should not enable the retry action"
        )
    }
}
