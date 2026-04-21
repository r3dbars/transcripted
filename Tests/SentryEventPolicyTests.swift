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
        let modelInitFailure = SentryEventPolicy.policy(
            forEngine: "parakeet",
            event: "model_init_failed"
        )
        let unknown = SentryEventPolicy.policy(
            forEngine: "dictation",
            event: "dictation_export_failed"
        )

        assertEqual(transcriptionFailure?.summary, "Speech transcription failed.", "transcription failure should use the normalized summary")
        assertEqual(hotkeyFailure?.summary, "Transcripted could not register a keyboard shortcut.", "capture failure should stay allowlisted")
        assertEqual(audioStartFailure?.summary, "Speech audio engine failed to start.", "audio-start failures should stay allowlisted with a privacy-safe summary")
        assertEqual(modelInitFailure?.summary, "Speech model initialization failed.", "model-init failures should stay allowlisted with a privacy-safe summary")
        assertNil(unknown, "unknown events should stay local-only by default")
    }
}
