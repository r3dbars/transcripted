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

    runSuite("FailedMeetingRecoveryPresentation - silent audio blocks retry with its own reason") {
        assertTrue(FailedMeetingRecoveryPresentation.retryDisabled(
            canRetry: true, isRetryable: true, isRetrying: false, hasAudioFiles: true,
            usableAudio: .absent
        ))
        assertEqual(
            FailedMeetingRecoveryPresentation.retryHelp(
                canRetry: true, retryUnavailableReason: nil,
                isRetryable: true, isRetrying: false, hasAudioFiles: true,
                usableAudio: .absent
            ),
            "The saved audio has no sound in it, so transcribing it again cannot produce a transcript.",
            "a silent artifact should say so rather than reusing the missing-audio copy"
        )
    }

    runSuite("FailedMeetingRecoveryPresentation - unprobed and present audio both stay offerable") {
        // Staying optimistic while the probe is in flight preserves the previous
        // behavior; only a completed probe can take the action away.
        for verdict in [FailedMeetingUsableAudio.unknown, .present] {
            assertFalse(
                FailedMeetingRecoveryPresentation.retryDisabled(
                    canRetry: true, isRetryable: true, isRetrying: false, hasAudioFiles: true,
                    usableAudio: verdict
                ),
                "\(verdict) should keep retry available"
            )
            assertEqual(
                FailedMeetingRecoveryPresentation.retryHelp(
                    canRetry: true, retryUnavailableReason: nil,
                    isRetryable: true, isRetrying: false, hasAudioFiles: true,
                    usableAudio: verdict
                ),
                "Transcribe this saved audio again."
            )
        }
    }

    runSuite("FailedMeetingRecoveryPresentation - in-flight retry outranks a stale silent verdict") {
        assertEqual(
            FailedMeetingRecoveryPresentation.retryHelp(
                canRetry: true, retryUnavailableReason: nil,
                isRetryable: true, isRetrying: true, hasAudioFiles: true,
                usableAudio: .absent
            ),
            "Retry is already running.",
            "a running retry should not be described as unusable audio"
        )
    }
}
