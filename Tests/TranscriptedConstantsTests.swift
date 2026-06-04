import Foundation

func testTranscriptedConstants() async {
    runSuite("TranscriptedConstants exposes the Parakeet minimum audio threshold") {
        assertEqual(TranscriptedConstants.parakeetMinimumInferenceSamples, 16_000, "Parakeet minimum sample count should match one second at 16kHz")
        assertFalse(TranscriptedConstants.hasMinimumParakeetAudioSamples(15_999), "sub-second audio should be rejected before transcription")
        assertTrue(TranscriptedConstants.hasMinimumParakeetAudioSamples(16_000), "one second of audio should be accepted")
        assertTrue(TranscriptedConstants.hasMinimumParakeetAudioSamples(20_000), "longer audio should still be accepted")
    }

    runSuite("TranscriptedConstants restores consumed borrowed clipboard before auto-enter") {
        assertTrue(
            TranscriptedConstants.clipboardRestoreDelay < TranscriptedConstants.dictationAutoEnterDelay,
            "clipboard restore should happen before follow-up keypresses and before users can easily paste stale dictation text"
        )
        assertTrue(
            TranscriptedConstants.clipboardRestoreFallbackDelay > TranscriptedConstants.clipboardRestoreDelay,
            "fallback restore should give slow paste consumers longer to read the borrowed dictation text"
        )
        assertTrue(
            TranscriptedConstants.clipboardRestoreFallbackDelay >= 2_000_000_000,
            "fallback restore should cover slower apps that consume Cmd+V after the old sub-second window"
        )
        assertTrue(
            TranscriptedConstants.clipboardRestoreFallbackDelay <= 3_000_000_000,
            "fallback restore should still return the user's clipboard promptly when no paste consumer reads it"
        )
        assertTrue(
            TranscriptedConstants.dictationAutoEnterDelay <= 150_000_000,
            "auto-enter should stay tuned for a fast opt-in stop path"
        )
    }

    runSuite("TranscriptedConstants keeps no-speech recovery copy readable") {
        assertTrue(
            TranscriptedConstants.noSpeechDismissDelay >= 2_000_000_000,
            "no-speech overlay should stay visible long enough to read the physical-key recovery hint"
        )
        assertTrue(
            TranscriptedConstants.noSpeechDismissDelay < TranscriptedConstants.errorDismissDelay,
            "no-speech recovery should still dismiss faster than regular error states"
        )
    }

    runSuite("TranscriptedConstants gives meeting quit preservation enough time") {
        let meetingStopTimeoutSeconds = TimeInterval(TranscriptedConstants.meetingStopTimeout) / 1_000_000_000
        assertTrue(
            TranscriptedConstants.meetingTerminationFinishWaitTimeout > meetingStopTimeoutSeconds,
            "termination wait should outlast meeting stop timeout so retained audio can be queued before quit"
        )
        let maximumStopTimeoutSeconds = TimeInterval(TranscriptedConstants.meetingMaximumStopTimeout) / 1_000_000_000
        assertTrue(
            TranscriptedConstants.meetingTerminationFinishWaitTimeout > maximumStopTimeoutSeconds,
            "termination wait should outlast the longest scaled stop timeout"
        )
    }

    runSuite("TranscriptedConstants scales meeting stop timeout for long recordings") {
        assertEqual(
            TranscriptedConstants.meetingStopTimeout(forRecordingDuration: 10 * 60),
            TranscriptedConstants.meetingStopTimeout,
            "short meetings should keep the fast base stop timeout"
        )
        assertEqual(
            TranscriptedConstants.meetingStopTimeout(forRecordingDuration: 119 * 60),
            TranscriptedConstants.meetingStopTimeout + (2 * TranscriptedConstants.meetingStopTimeoutGrowthStep),
            "meetings close to two hours should get the two-hour stop budget"
        )
        assertEqual(
            TranscriptedConstants.meetingStopTimeout(forRecordingDuration: 2 * 60 * 60),
            TranscriptedConstants.meetingStopTimeout + (2 * TranscriptedConstants.meetingStopTimeoutGrowthStep),
            "two-hour meetings should get extra time to flush and merge audio"
        )
        assertEqual(
            TranscriptedConstants.meetingStopTimeout(forRecordingDuration: 12 * 60 * 60),
            TranscriptedConstants.meetingMaximumStopTimeout,
            "very long meetings should cap the stop wait"
        )
    }

    runSuite("TranscriptedConstants keeps failed meeting audio cleanup conservative") {
        assertTrue(
            TranscriptedConstants.failedMeetingAudioRetentionDays >= 30,
            "failed meeting audio should stay recoverable long enough for users to retry or delete it intentionally"
        )
    }

    await runSuite("TranscriptedConstants.withTimeout — returns completed work before deadline") {
        let result = try? await TranscriptedConstants.withTimeout(seconds: 1) {
            "ok"
        }

        assertEqual(result, "ok", "completed async work should return its value")
    }

    await runSuite("TranscriptedConstants.withTimeout — cancels work after deadline") {
        let result = try? await TranscriptedConstants.withTimeout(seconds: 0.01) {
            try await Task.sleep(nanoseconds: 1_000_000_000)
            return "late"
        }

        assertNil(result, "timeout should return through the throwing path instead of hanging")
    }
}
