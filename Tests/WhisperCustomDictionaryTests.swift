// WhisperCustomDictionaryTests.swift
// Guards that the Whisper STT path applies the user's custom dictionary, the
// same way ParakeetEngine does.
//
// Whisper used to return transcribed text verbatim, so a user who taught the
// app their proper nouns got those corrections on Parakeet but silently not on
// Whisper. WhisperEngine can't be instantiated in the fast runner (it pulls in
// WhisperKit), so this pairs a behavioral check of the processor with a
// source-level contract that the Whisper return value routes through it.

import Foundation

func testWhisperCustomDictionary() {
    // Behavioral: a populated dictionary actually rewrites the text the Whisper
    // path would return, and an empty dictionary is a safe no-op.
    runSuite("CustomDictionary correction applied on a Whisper-style transcript") {
        let entries = [
            CustomDictionaryEntry(spoken: "post hog", replacement: "PostHog"),
            CustomDictionaryEntry(spoken: "jay son", replacement: "JSON"),
        ]
        let raw = "we shipped post hog events and parsed the jay son payload"
        let corrected = CustomDictionaryTextProcessor.apply(to: raw, entries: entries)

        assertEqual(
            corrected,
            "we shipped PostHog events and parsed the JSON payload",
            "the Whisper path must apply custom proper-noun corrections"
        )
    }

    runSuite("Empty custom dictionary leaves Whisper output untouched") {
        let raw = "nothing to correct here"
        assertEqual(
            CustomDictionaryTextProcessor.apply(to: raw, entries: []),
            raw,
            "an empty dictionary must be a no-op on the Whisper path"
        )
    }

    // Source contract: the Whisper engine's success return must pass through the
    // custom-dictionary processor, not return the raw transcript.
    runSuite("WhisperEngine routes its transcript through CustomDictionaryTextProcessor") {
        let source = whisperEngineSource()

        assertTrue(
            source.contains("CustomDictionaryTextProcessor.apply(to: trimmed)"),
            "WhisperEngine should return CustomDictionaryTextProcessor.apply(to: trimmed)"
        )
        assertFalse(
            source.contains("return trimmed\n"),
            "WhisperEngine should not return the un-corrected transcript directly"
        )
    }
}

private func whisperEngineSource() -> String {
    let url = URL(fileURLWithPath: FileManager.default.currentDirectoryPath, isDirectory: true)
        .appendingPathComponent("Sources/Speech/WhisperEngine.swift")
    return (try? String(contentsOf: url, encoding: .utf8)) ?? ""
}
