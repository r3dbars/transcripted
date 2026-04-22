import Foundation

func testTranscriptedConstants() async {
    runSuite("TranscriptedConstants exposes the Parakeet minimum audio threshold") {
        assertEqual(TranscriptedConstants.parakeetMinimumInferenceSamples, 16_000, "Parakeet minimum sample count should match one second at 16kHz")
        assertFalse(TranscriptedConstants.hasMinimumParakeetAudioSamples(15_999), "sub-second audio should be rejected before transcription")
        assertTrue(TranscriptedConstants.hasMinimumParakeetAudioSamples(16_000), "one second of audio should be accepted")
        assertTrue(TranscriptedConstants.hasMinimumParakeetAudioSamples(20_000), "longer audio should still be accepted")
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
