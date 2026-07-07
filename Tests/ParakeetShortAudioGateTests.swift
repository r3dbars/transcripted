import Foundation

func testParakeetShortAudioGate() {
    runSuite("ParakeetShortAudioGate.dictation — threshold-length audio transcribes") {
        let decision = ParakeetShortAudioGate.dictation(
            nativeSampleCount: 48_000,
            resampledSampleCount: TranscriptedConstants.parakeetMinimumInferenceSamples
        )

        assertTrue(decision.shouldTranscribe, "one second of Parakeet audio should still transcribe")
        assertNil(decision.event, "transcribable dictation should not emit a skip event")
        assertEqual(decision.context, [:], "transcribable dictation should not attach skip diagnostics")
    }

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

    runSuite("ParakeetShortAudioGate.dictationFallback — treats invalid-audio errors as short-audio skips") {
        let decision = ParakeetShortAudioGate.dictationFallback(
            nativeSampleCount: 43_200,
            resampledSampleCount: 14_400,
            errorMessage: "Invalid audio data provided. Must be at least 1 second of 16kHz audio."
        )

        assertEqual(decision?.event, "recording_too_short", "short-audio failures should collapse into the dedicated skip event")
        assertEqual(decision?.context["samples"], "14400", "fallback skips should preserve the failing sample count")
    }

    runSuite("ParakeetShortAudioGate.meetingSegmentFallback — protects the meeting pipeline from short-audio throws") {
        let decision = ParakeetShortAudioGate.meetingSegmentFallback(
            sampleCount: 15_500,
            sourceDescription: "microphone",
            errorMessage: "Recording too short for inference"
        )

        assertEqual(decision?.event, "segment_too_short", "meeting fallback should reuse the dedicated short-segment event")
        assertEqual(decision?.context["source"], "microphone", "meeting fallback should preserve which stream failed")
    }

    runSuite("ParakeetShortAudioGate.dictationFallback — ignores unrelated inference failures when audio is long enough") {
        let decision = ParakeetShortAudioGate.dictationFallback(
            nativeSampleCount: 96_000,
            resampledSampleCount: 32_000,
            errorMessage: "GPU memory pressure"
        )

        assertNil(decision, "non-short-audio failures should still surface as real transcription errors")
    }

    runSuite("DictationEmptyTranscriptionReason keeps too-short telemetry out of no-speech") {
        assertEqual(
            DictationEmptyTranscriptionReason.recordingTooShort.analyticsEventName,
            "dictation_recording_too_short",
            "short dictation should not inflate dictation_no_speech analytics"
        )
        assertEqual(
            DictationEmptyTranscriptionReason.recordingTooShort.localEventName,
            "dictation_recording_too_short",
            "local diagnostics should use the same explicit short-recording event"
        )
        assertEqual(
            DictationEmptyTranscriptionReason.noSpeech.analyticsEventName,
            "dictation_no_speech",
            "real no-speech dictation should keep the existing analytics event"
        )
        assertEqual(
            DictationEmptyTranscriptionReason.modelFailure.analyticsEventName,
            "dictation_transcription_failed",
            "model runtime errors should not inflate no-speech analytics"
        )
        assertEqual(
            DictationEmptyTranscriptionReason.modelFailure.localEventName,
            "dictation_transcription_failed",
            "local diagnostics should name model failures explicitly"
        )
    }
}
