// WhisperCustomDictionaryTests.swift
// Guards that the Whisper STT path applies the user's custom dictionary, the
// same way ParakeetEngine does.
//
// Whisper used to return transcribed text verbatim, so a user who taught the
// app their proper nouns got those corrections on Parakeet but silently not on
// Whisper. WhisperEngine can't be instantiated in the fast runner (it pulls in
// WhisperKit), so it builds its return value with SegmentedEngineTranscript,
// which these tests drive directly.

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

    runSuite("Whisper's joined segments come back with dictionary corrections") {
        let entries = [CustomDictionaryEntry(spoken: "post hog", replacement: "PostHog")]
        let transcript = SegmentedEngineTranscript(
            segmentTexts: ["  we shipped post", "hog events  "],
            entries: entries
        )
        assertEqual(transcript.uncorrected, "we shipped post hog events", "segments join with one space and lose outer whitespace")
        assertEqual(transcript.text, "we shipped PostHog events", "a correction can span a segment boundary")

        let plain = SegmentedEngineTranscript(segmentTexts: [" hello ", " "], entries: [])
        assertEqual(plain.text, "hello", "an empty dictionary returns the trimmed text unchanged")
    }
}
