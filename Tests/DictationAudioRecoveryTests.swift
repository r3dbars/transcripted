import Foundation

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
        let engineSource = (try? String(
            contentsOf: repoFixtureURL("Sources/Speech/ParakeetEngine.swift"),
            encoding: .utf8
        )) ?? ""
        let sessionSource = (try? String(
            contentsOf: repoFixtureURL("Sources/UI/Overlay/DictationSessionController.swift"),
            encoding: .utf8
        )) ?? ""

        assertTrue(
            engineSource.contains("private var recoveredRecordingTimeline = RecordedAudioTimeline()"),
            "engine should keep a multi-segment audio timeline for route-change recovery"
        )
        assertTrue(
            engineSource.contains("preserveCurrentRecordingBuffersForRecovery()"),
            "config changes during recording should preserve buffered audio before tearing down the tap"
        )
        assertTrue(
            engineSource.contains("recoveredRecordingTimeline.append(sampleBuffer, sampleRate: safeNativeSampleRate())"),
            "current-device audio should be retained with its native sample rate"
        )
        assertTrue(
            engineSource.contains("private func clearRecoveredRecordingTimeline(keepingCapacity: Bool = true)"),
            "recovery preservation should have a single cleanup path"
        )
        assertTrue(
            engineSource.contains("private func interruptRecordingAndClearRecoveredTimeline()"),
            "interrupted recovery should clear preserved audio before publishing interruption"
        )
        let directInterruptAssignments = engineSource.components(separatedBy: "recordingInterrupted = true").count - 1
        assertEqual(
            directInterruptAssignments,
            1,
            "all recording interruption paths should go through the cleanup helper"
        )
        assertTrue(
            sessionSource.contains("appState.sttRouter.cancel()\n            let failureKind"),
            "abandoned capture-not-started sessions should cancel the speech engine and clear preserved recovery audio"
        )
        assertTrue(
            engineSource.contains("drainRecordedSamplesForInference()"),
            "transcription should drain preserved segments instead of resampling all audio as one rate"
        )
    }
}
