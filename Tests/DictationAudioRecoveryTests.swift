// DictationAudioRecoveryTests.swift
//
// Two kinds of coverage live in this file; they are NOT the same strength of proof:
//
// REAL BEHAVIORAL COVERAGE (compiled): the first four suites exercise the Foundation-pure
// DictationAudioRecovery type compiled into the fast-test runner — silence detection,
// quiet-speech focus/normalize/retry, sub-threshold burst rejection, and non-finite
// sample-rate handling. These run the real logic and assert real outputs (analysis flags,
// diagnostic context, retry sample shaping).
//
// The last suite ("preserves dictation audio across route recovery") runs the compiled
// ParakeetInterruptionTerminal, the one helper ParakeetEngine marks a recording interrupted
// through, against a fake engine state. The multi-rate timeline is covered by
// RecordedAudioTimelineTests, and buffer preservation across recovery by
// ParakeetAudioGraphTests.

import Foundation

/// Stands in for ParakeetEngine's restart flags and its published
/// interruption.
@MainActor
private final class FakeInterruptionTerminalState: ParakeetInterruptionTerminalState {
    var preservingRecordingAcrossRecovery = true
    var configChangeWasRecording = true
    var recordingInterrupted = false
}

@MainActor
func testDictationAudioRecovery() {
    runSuite("DictationAudioRecovery.analyze — detects silent audio") {
        let samples = [Float](repeating: 0, count: 32_000)
        let analysis = DictationAudioRecovery.analyze(
            samples: samples,
            sampleRate: TranscriptedConstants.parakeetSampleRate
        )

        assertFalse(analysis.hasUsableSpeechSignal, "silence should not be treated as recoverable speech")
        assertEqual(analysis.context["audio_has_signal"], "false", "diagnostic context should record silence")
        assertNil(
            DictationAudioRecovery.retrySamples(
                from: samples,
                sampleRate: TranscriptedConstants.parakeetSampleRate,
                analysis: analysis
            ),
            "silent audio should not be amplified into a retry"
        )
    }

    runSuite("DictationAudioRecovery.retrySamples — focuses and normalizes quiet speech-like audio") {
        var samples = [Float](repeating: 0, count: 64_000)
        for index in 20_000..<44_000 {
            samples[index] = index.isMultiple(of: 2) ? 0.018 : -0.018
        }

        let analysis = DictationAudioRecovery.analyze(
            samples: samples,
            sampleRate: TranscriptedConstants.parakeetSampleRate
        )
        let retry = DictationAudioRecovery.retrySamples(
            from: samples,
            sampleRate: TranscriptedConstants.parakeetSampleRate,
            analysis: analysis
        )

        assertTrue(analysis.hasUsableSpeechSignal, "quiet but sustained audio should be recoverable")
        assertNotNil(retry, "recoverable audio should produce retry samples")
        assertTrue((retry?.count ?? 0) < samples.count, "retry audio should trim outer silence")
        assertTrue((retry?.count ?? 0) >= TranscriptedConstants.parakeetMinimumInferenceSamples, "retry audio should stay long enough for Parakeet")
        assertTrue((retry?.map(abs).max() ?? 0) > analysis.peak, "retry audio should be normalized upward")
    }

    runSuite("DictationAudioRecovery.retrySamples — refuses sub-threshold bursts") {
        var samples = [Float](repeating: 0, count: 64_000)
        for index in 30_000..<31_000 {
            samples[index] = index.isMultiple(of: 2) ? 0.04 : -0.04
        }

        let analysis = DictationAudioRecovery.analyze(
            samples: samples,
            sampleRate: TranscriptedConstants.parakeetSampleRate
        )

        assertFalse(analysis.hasUsableSpeechSignal, "short bursts should not look like dictation")
        assertNil(
            DictationAudioRecovery.retrySamples(
                from: samples,
                sampleRate: TranscriptedConstants.parakeetSampleRate,
                analysis: analysis
            ),
            "short bursts should not be retried"
        )
    }

    runSuite("DictationAudioRecovery — rejects non-finite sample rates") {
        let samples = [Float](repeating: 0.02, count: 32_000)

        for sampleRate in [Double.nan, Double.infinity, -Double.infinity, 0.0, 7_999.0, 384_001.0] {
            let analysis = DictationAudioRecovery.analyze(samples: samples, sampleRate: sampleRate)

            assertEqual(analysis.durationSeconds, 0, "invalid sample rates should not compute duration")
            assertFalse(analysis.hasUsableSpeechSignal, "invalid sample rates should not look recoverable")
            assertNil(
                DictationAudioRecovery.retrySamples(from: samples, sampleRate: sampleRate, analysis: analysis),
                "invalid sample rates should not request retry samples"
            )
        }
    }

    runSuite("ParakeetEngine — preserves dictation audio across route recovery") {
        let state = FakeInterruptionTerminalState()
        var seenAtPublish: (preserving: Bool, configChange: Bool)?
        ParakeetInterruptionTerminal.apply(state: state) {
            seenAtPublish = (state.preservingRecordingAcrossRecovery, state.configChangeWasRecording)
            state.recordingInterrupted = true
        }
        assertTrue(state.recordingInterrupted, "the interruption is published")
        assertEqual(seenAtPublish?.preserving, false, "terminal interruption must clear restart intent before notifying its subscriber")
        assertEqual(seenAtPublish?.configChange, false, "terminal interruption must reset every restart flag before notifying its subscriber")
        // Captured speech stays for explicit recovery by construction: the
        // terminal only sees the restart flags (ParakeetInterruptionTerminalState),
        // never the recorded timeline, so it can't call removeAll on it.
        // Dropped: the count of `recordingInterrupted = true` assignments in the
        // engine source. Which paths call the helper is code shape, not a promise
        // a test can observe; the ordering it existed to protect is checked above.
        // The controller's half moved to behavior tests in
        // DictationSessionPipelineTests.swift: "A stop before capture started
        // cancels the engine and offers a retried start" and "A stale stop
        // task touches nothing". The stop stage reads no recording state
        // before stopping the mic, so a brief recovery-idle state can't skip
        // the stop ("The mic stop runs first, whatever the session state" in
        // DictationStopCheckpointTests.swift).
    }
}
