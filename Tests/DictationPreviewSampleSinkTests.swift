import Foundation

// Promises: the live-preview sink hands back captured audio as 16 kHz mono,
// feeding each captured segment to the resampler exactly once (no repeats, no
// drops), and a take with nothing new captured returns nothing.
func testDictationPreviewSampleSink() {
    runSuite("Preview sink passes 16 kHz audio through unchanged") {
        let sink = DictationPreviewSampleSink()
        let samples: [Float] = (0..<1_600).map { Float($0 % 50) / 100 }
        sink.append(samples, sampleRate: 16_000)
        assertEqual(sink.take(), samples, "16 kHz input comes back sample for sample")
        assertEqual(sink.take().count, 0, "a second take with nothing new captured is empty")
    }

    runSuite("Preview sink resamples 48 kHz audio to 16 kHz once per captured segment") {
        let sink = DictationPreviewSampleSink()
        let oneSecond: [Float] = (0..<48_000).map { sinf(Float($0) * 2 * .pi * 440 / 48_000) * 0.5 }
        sink.append(oneSecond, sampleRate: 48_000)
        let first = sink.take()
        // One second at 16 kHz is 16,000 samples. The converter may hold a
        // filter's worth back for the next take, but feeding the segment
        // twice would come back near 32,000.
        assertTrue(first.count > 15_000, "a second of 48 kHz audio yields about a second at 16 kHz (got \(first.count))")
        assertTrue(first.count <= 16_000, "the segment is fed to the converter once, not repeated (got \(first.count))")
        assertTrue(first.contains { abs($0) > 0.1 }, "the resampled audio keeps its signal")

        sink.append(oneSecond, sampleRate: 48_000)
        let second = sink.take()
        assertTrue(second.count > 15_000 && second.count <= 16_500,
                   "the next take resamples only the newly captured second (got \(second.count))")
    }
}
