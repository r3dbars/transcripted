import Foundation

func testParakeetShortAudioGate() {
    runSuite("ParakeetShortAudioGate.dictation — short audio skips without transcription failure semantics") {
        let decision = ParakeetShortAudioGate.dictation(
            nativeSampleCount: 24_000,
            resampledSampleCount: 8_000
        )

        assertFalse(decision.shouldTranscribe, "sub-second dictation should be skipped")
        assertEqual(decision.event, "recording_too_short", "short dictation should emit the non-error skip event")
        assertEqual(decision.message, "Dictation audio too short for transcription", "short dictation should use the user-facing skip message")
        assertEqual(decision.context["native_samples"], "24000", "native sample count should be preserved for diagnostics")
        assertEqual(decision.context["samples"], "8000", "resampled sample count should be preserved for diagnostics")
        assertEqual(decision.context["audio_duration_s"], "0.50", "duration should be reported in seconds at the 16kHz inference rate")
        assertEqual(decision.context["minimum_samples"], "16000", "minimum Parakeet threshold should stay attached to the skip context")
        assertFalse(decision.event == "transcription_failed", "short dictation should not look like a transcription failure")
    }

    runSuite("ParakeetShortAudioGate.meetingSegment — short segments are skipped while threshold-length audio still transcribes") {
        let skipped = ParakeetShortAudioGate.meetingSegment(
            sampleCount: 4_000,
            sourceDescription: "system"
        )
        let transcribes = ParakeetShortAudioGate.meetingSegment(
            sampleCount: TranscriptedConstants.parakeetMinimumInferenceSamples,
            sourceDescription: "microphone"
        )

        assertFalse(skipped.shouldTranscribe, "short meeting segments should be skipped")
        assertEqual(skipped.event, "segment_too_short", "meeting segments should use the dedicated short-segment event")
        assertEqual(skipped.message, "Skipped short audio segment before Parakeet transcription", "meeting skips should preserve the existing message")
        assertEqual(skipped.context["audio_duration_s"], "0.25", "meeting skip diagnostics should include segment duration")
        assertEqual(skipped.context["source"], "system", "meeting skip diagnostics should preserve the source label")
        assertTrue(transcribes.shouldTranscribe, "threshold-length meeting segments should still transcribe")
        assertNil(transcribes.event, "transcribable segments should not attach a skip event")
        assertEqual(transcribes.context, [:], "transcribable segments should not attach skip-only diagnostics")
    }
}
