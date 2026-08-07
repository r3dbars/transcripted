import Foundation

func testFailedMeetingRecoveryPresentation() {
    runSuite("FailedMeetingRecoveryPresentation - retry enabled with retained audio") {
        assertFalse(FailedMeetingRecoveryPresentation.retryDisabled(
            canRetry: true, isRetryable: true, isRetrying: false, hasAudioFiles: true
        ))
        assertEqual(
            FailedMeetingRecoveryPresentation.retryHelp(
                canRetry: true, retryUnavailableReason: nil,
                isRetryable: true, isRetrying: false, hasAudioFiles: true
            ),
            "Transcribe this saved audio again."
        )
    }

    runSuite("FailedMeetingRecoveryPresentation - retry blocked by active work") {
        assertTrue(FailedMeetingRecoveryPresentation.retryDisabled(
            canRetry: false, isRetryable: true, isRetrying: false, hasAudioFiles: true
        ))
        assertEqual(
            FailedMeetingRecoveryPresentation.retryHelp(
                canRetry: false, retryUnavailableReason: "Wait for model prep to finish.",
                isRetryable: true, isRetrying: false, hasAudioFiles: true
            ),
            "Wait for model prep to finish."
        )
    }

    runSuite("FailedMeetingRecoveryPresentation - missing audio wins over unavailable reason") {
        assertTrue(FailedMeetingRecoveryPresentation.retryDisabled(
            canRetry: true, isRetryable: true, isRetrying: false, hasAudioFiles: false
        ))
        assertEqual(
            FailedMeetingRecoveryPresentation.retryHelp(
                canRetry: true, retryUnavailableReason: "Wait for another job.",
                isRetryable: true, isRetrying: false, hasAudioFiles: false
            ),
            "This meeting does not have enough saved audio to retry."
        )
    }

    runSuite("FailedMeetingRecoveryPresentation - retrying state stays disabled") {
        assertTrue(FailedMeetingRecoveryPresentation.retryDisabled(
            canRetry: true, isRetryable: true, isRetrying: true, hasAudioFiles: true
        ))
        assertEqual(
            FailedMeetingRecoveryPresentation.retryHelp(
                canRetry: true, retryUnavailableReason: nil,
                isRetryable: true, isRetrying: true, hasAudioFiles: true
            ),
            "Retry is already running."
        )
    }

    runSuite("FailedMeetingRecoveryPresentation - busy fallback explains active work") {
        assertTrue(FailedMeetingRecoveryPresentation.retryDisabled(
            canRetry: false, isRetryable: true, isRetrying: false, hasAudioFiles: true
        ))
        assertEqual(
            FailedMeetingRecoveryPresentation.retryHelp(
                canRetry: false, retryUnavailableReason: nil,
                isRetryable: true, isRetrying: false, hasAudioFiles: true
            ),
            "Wait for the current meeting work to finish before retrying."
        )
    }
}
