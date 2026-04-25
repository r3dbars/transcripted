import Foundation

func testMeetingFailureKind() {
    runSuite("MeetingFailureKind classifies recording-too-short errors") {
        let kind = MeetingFailureKind.classify(
            message: "Invalid audio data provided. Must be at least 1 second of 16kHz audio."
        )

        assertEqual(kind, .recordingTooShort, "short captures should stay out of the generic bucket")
    }

    runSuite("MeetingFailureKind does not overmatch generic minimum language") {
        let kind = MeetingFailureKind.classify(
            message: "Upload failed after at least one retry because the destination was unavailable."
        )

        assertEqual(kind, .unexpectedError, "minimum-language without audio context should not become recording_too_short")
    }

    runSuite("MeetingFailureKind keeps generic invalid audio separate from short recordings") {
        let kind = MeetingFailureKind.classify(
            message: "Invalid audio data: file header could not be decoded."
        )

        assertEqual(kind, .invalidAudioFormat, "generic invalid audio should not masquerade as a too-short recording")
    }

    runSuite("MeetingFailureKind classifies diarization failures") {
        let kind = MeetingFailureKind.classify(
            message: "PyAnnote inference failed: model weights missing"
        )

        assertEqual(kind, .diarizationFailed, "diarization-specific failures should be preserved for analytics")
    }

    runSuite("MeetingFailureKind classifies save failures") {
        let kind = MeetingFailureKind.classify(
            message: "Failed to save transcript: Could not write transcript to meetings"
        )

        assertEqual(kind, .saveFailed, "save failures should keep their own analytics bucket")
    }

    runSuite("MeetingFailureKind classifies pipeline-busy errors") {
        let kind = MeetingFailureKind.classify(
            message: "Transcription already in progress"
        )

        assertEqual(kind, .pipelineBusy, "pipeline-busy rejections from TranscriptionTaskManager should not fall to unexpected_error")
    }

    runSuite("MeetingFailureKind classifies stop-timeout errors") {
        let kind = MeetingFailureKind.classify(
            message: "Recording stop timed out before audio files were finalized."
        )

        assertEqual(kind, .stopTimeout, "stop-timeout failures should keep their own bucket so retry copy can target them")
    }

    runSuite("MeetingFailureCopy surfaces stop-timeout retry guidance") {
        let copy = MeetingFailureCopy.make(
            forMessage: "Recording stop timed out before audio files were finalized.",
            shortErrorMessage: "Recording stop timed out.",
            isRetryable: true
        )

        assertEqual(copy.title, "Recording didn't close cleanly", "stop-timeout users should see specific copy, not generic retry phrasing")
    }

    runSuite("MeetingFailureKind falls back to an explicit unexpected bucket") {
        let kind = MeetingFailureKind.classify(
            message: "Something odd happened while processing the meeting"
        )

        assertEqual(kind, .unexpectedError, "unknown failures should avoid the vague 'other' label")
    }
}
