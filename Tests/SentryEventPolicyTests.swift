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
        let unknown = SentryEventPolicy.policy(
            forEngine: "dictation",
            event: "dictation_export_failed"
        )

        assertEqual(transcriptionFailure?.summary, "Speech transcription failed.", "transcription failure should use the normalized summary")
        assertEqual(hotkeyFailure?.summary, "Transcripted could not register a keyboard shortcut.", "capture failure should stay allowlisted")
        assertNil(unknown, "unknown events should stay local-only by default")
    }
}
