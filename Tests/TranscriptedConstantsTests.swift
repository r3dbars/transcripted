import Foundation

func testTranscriptedConstants() {
    runSuite("TranscriptedConstants exposes the Parakeet minimum audio threshold") {
        assertEqual(TranscriptedConstants.parakeetMinimumInferenceSamples, 16_000, "Parakeet minimum sample count should match one second at 16kHz")
        assertFalse(TranscriptedConstants.hasMinimumParakeetAudioSamples(15_999), "sub-second audio should be rejected before transcription")
        assertTrue(TranscriptedConstants.hasMinimumParakeetAudioSamples(16_000), "one second of audio should be accepted")
        assertTrue(TranscriptedConstants.hasMinimumParakeetAudioSamples(20_000), "longer audio should still be accepted")
    }
}
