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
// IMPLEMENTATION-PINNING STRUCTURAL CONTRACTS (NOT compiled): the final suite
// ("preserves dictation audio across route recovery") reads
// Sources/Speech/ParakeetEngine.swift and Sources/UI/Overlay/DictationSessionController.swift
// as TEXT and asserts presence of specific declarations / call sites and a single
// canonical `recordingInterrupted = true` assignment. Both sources are
// CoreAudio/SwiftUI-wired and are NOT compiled into this Foundation-only runner, so these
// greps pin source structure, not runtime behavior. They guard the REAL invariant that
// audio buffered before a mid-recording route change is preserved across teardown (so a
// device switch does not silently drop dictation audio), and that every interruption path
// routes through the single cleanup helper. They are intentionally kept as source-text
// contracts rather than a runtime seam: extracting one would restructure real-time
// CoreAudio recovery/teardown control flow, which is too risky to refactor for
// testability. If you move/rename these declarations or change the interruption path,
// update both the source and these greps together.

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
            engineSource.contains("var recoveredRecordingTimeline = RecordedAudioTimeline()"),
            "engine should keep a multi-segment audio timeline for route-change recovery"
        )
        assertTrue(
            engineSource.contains("preserveCurrentRecordingBuffersForRecovery()"),
            "config changes during recording should preserve buffered audio before tearing down the tap"
        )
        assertTrue(
            engineSource.contains("recoveredRecordingTimeline.append(segment.samples, sampleRate: segment.sampleRate)"),
            "current-device audio should be retained with its native sample rate"
        )
        assertTrue(
            engineSource.contains("func clearRecoveredRecordingTimeline(keepingCapacity: Bool = true)"),
            "recovery preservation should have a single cleanup path"
        )
        assertTrue(
            engineSource.contains("func interruptRecordingAndClearRecoveredTimeline()"),
            "interrupted recovery should clear preserved audio before publishing interruption"
        )
        if let start = engineSource.range(of: "private func markRecordingInterrupted()"),
           let end = engineSource.range(of: "private func cancelPendingRecordingRecovery", range: start.upperBound..<engineSource.endIndex) {
            let terminal = String(engineSource[start.lowerBound..<end.lowerBound])
            let publication = terminal.range(of: "recordingInterrupted = true")
            for reset in ["preservingRecordingAcrossRecovery = false", "configChangeWasRecording = false"] {
                if let resetRange = terminal.range(of: reset), let publication {
                    assertTrue(resetRange.lowerBound < publication.lowerBound, "terminal interruption must clear restart intent before notifying its subscriber")
                } else {
                    assertTrue(false, "terminal interruption must reset every restart flag")
                }
            }
            assertFalse(terminal.contains("removeAll"), "clearing restart intent must retain captured speech for explicit recovery")
        } else {
            assertTrue(false, "interruption publication should have one terminal helper")
        }
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
            sessionSource.contains("await appState.sttRouter.stopRecording()\n            stopTiming.micStoppedAt"),
            "an admitted stop must always reach the engine so a temporary recovery-idle state cannot revive the microphone"
        )
        guard let stopTaskOwner = sessionSource.range(of: "let taskSessionID = currentDictationSessionID"),
              let preStopGuard = sessionSource.range(
                of: "guard !Task.isCancelled,",
                range: stopTaskOwner.upperBound..<sessionSource.endIndex
              ),
              let stopDiagnostic = sessionSource.range(
                of: "appState.runtimeDiagnostics.recordSession(kind: \"dictation\", stage: \"stop_requested\")",
                range: preStopGuard.upperBound..<sessionSource.endIndex
              ),
              let stopCall = sessionSource.range(
                of: "await appState.sttRouter.stopRecording()",
                range: stopDiagnostic.upperBound..<sessionSource.endIndex
              ) else {
            assertTrue(false, "stop task should gate diagnostics and engine mutation on exact session ownership")
            return
        }
        assertTrue(
            preStopGuard.lowerBound < stopDiagnostic.lowerBound
                && stopDiagnostic.lowerBound < stopCall.lowerBound,
            "a cancelled stale stop task must not stop or relabel a successor dictation session"
        )
        assertFalse(
            sessionSource.contains("if appState.sttRouter.isRecording || appState.sttRouter.hasRecoverableRecording {\n                await appState.sttRouter.stopRecording()"),
            "the stop task must not re-check transient recording state before cancelling recovery"
        )
        assertTrue(
            engineSource.contains("drainRecordedSamplesForInference()"),
            "transcription should drain preserved segments instead of resampling all audio as one rate"
        )
    }
}
