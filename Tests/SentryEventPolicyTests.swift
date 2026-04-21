import Foundation

func testSentryEventPolicy() {
    runSuite("SentryEventPolicy returns policies only for explicitly allowlisted events") {
        let transcriptionFailure = SentryEventPolicy.policy(
            forEngine: "parakeet",
            event: "transcription_failed"
        )
        let hotkeyFailure = SentryEventPolicy.policy(
            forEngine: "capture",
            event: "hotkey_register_failed"
        )
        let audioStartFailure = SentryEventPolicy.policy(
            forEngine: "parakeet",
            event: "audio_engine_start_failed"
        )
        let microphoneStartTimeout = SentryEventPolicy.policy(
            forEngine: "dictation",
            event: "microphone_start_timeout"
        )
        let unknown = SentryEventPolicy.policy(
            forEngine: "dictation",
            event: "dictation_export_failed"
        )

        assertEqual(transcriptionFailure?.summary, "Speech transcription failed.", "transcription failure should use the normalized summary")
        assertEqual(hotkeyFailure?.summary, "Transcripted could not register a keyboard shortcut.", "capture failure should stay allowlisted")
        assertEqual(audioStartFailure?.summary, "Speech audio engine failed to start.", "audio-start failures should stay allowlisted with a privacy-safe summary")
        assertEqual(microphoneStartTimeout?.summary, "Dictation microphone start timed out.", "microphone start timeouts should be visible in Sentry without raw device names")
        assertNil(unknown, "unknown events should stay local-only by default")
    }
}
