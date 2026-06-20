import Foundation

func testFailedMeetingRecoveryPresentation() {
    runSuite("FailedMeetingRecoveryPresentation - retry enabled with retained audio") {
        let presentation = FailedMeetingRecoveryPresentation.make(
            failureKind: .unexpectedError,
            canRetry: true,
            retryUnavailableReason: nil,
            isRetryable: true,
            isRetrying: false,
            hasAudioFiles: true,
            hasRetainedAudioFiles: true
        )

        assertEqual(presentation.iconSystemName, "exclamationmark.triangle.fill")
        assertEqual(presentation.iconTone, .warning)
        assertFalse(presentation.retryDisabled)
        assertEqual(presentation.retryHelp, "Transcribe this saved audio again.")
        assertEqual(presentation.clearTitle, "Delete")
        assertEqual(presentation.clearSymbolName, "trash")
        assertTrue(presentation.clearIsDestructive)
    }

    runSuite("FailedMeetingRecoveryPresentation - retry blocked by active work") {
        let presentation = FailedMeetingRecoveryPresentation.make(
            failureKind: .recordingTooShort,
            canRetry: false,
            retryUnavailableReason: "Wait for model prep to finish.",
            isRetryable: true,
            isRetrying: false,
            hasAudioFiles: true,
            hasRetainedAudioFiles: false
        )

        assertEqual(presentation.iconSystemName, "timer")
        assertEqual(presentation.iconTone, .neutral)
        assertTrue(presentation.retryDisabled)
        assertEqual(presentation.retryHelp, "Wait for model prep to finish.")
        assertEqual(presentation.clearTitle, "Dismiss")
        assertEqual(presentation.clearSymbolName, "xmark")
        assertFalse(presentation.clearIsDestructive)
    }

    runSuite("FailedMeetingRecoveryPresentation - missing audio wins over unavailable reason") {
        let presentation = FailedMeetingRecoveryPresentation.make(
            failureKind: .emptyAudio,
            canRetry: true,
            retryUnavailableReason: "Wait for another job.",
            isRetryable: true,
            isRetrying: false,
            hasAudioFiles: false,
            hasRetainedAudioFiles: false
        )

        assertTrue(presentation.retryDisabled)
        assertEqual(presentation.retryHelp, "This meeting does not have enough saved audio to retry.")
    }

    runSuite("FailedMeetingRecoveryPresentation - retrying state stays disabled") {
        let presentation = FailedMeetingRecoveryPresentation.make(
            failureKind: .unexpectedError,
            canRetry: true,
            retryUnavailableReason: nil,
            isRetryable: true,
            isRetrying: true,
            hasAudioFiles: true,
            hasRetainedAudioFiles: true
        )

        assertTrue(presentation.retryDisabled)
        assertEqual(presentation.retryHelp, "Retry is already running.")
    }

    runSuite("FailedMeetingRecoveryPresentation - busy fallback explains active work") {
        let presentation = FailedMeetingRecoveryPresentation.make(
            failureKind: .unexpectedError,
            canRetry: false,
            retryUnavailableReason: nil,
            isRetryable: true,
            isRetrying: false,
            hasAudioFiles: true,
            hasRetainedAudioFiles: true
        )

        assertTrue(presentation.retryDisabled)
        assertEqual(presentation.retryHelp, "Wait for the current meeting work to finish before retrying.")
    }
}
