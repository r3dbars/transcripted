// DictationSessionDecisionTests.swift
// DictationSession is @MainActor and takes TranscriptedAppState by parameter
// (not at construction), so the bare object — and the pure decisions it
// exposes — are fast-testable even though DictationSessionController pulls
// in the whole app and can't be instantiated here (see
// DictationSessionCapTests.swift). This suite covers the StartPathDecision
// policy the wait-loop extraction introduced and the WaitStatus value type.
//
// DictationSession intentionally has no published lifecycle/state enum to
// test here — see the NOTE at the top of Sources/Speech/DictationSessionTypes.swift.

import Foundation

@MainActor
func testDictationSessionDecision() async {
    runSuite("DictationSession.StartPathDecision — loaded model starts immediately") {
        let decision = DictationSession.StartPathDecision.decide(
            isRecordingModelLoaded: true,
            recordingModelLoadFailed: false
        )
        assertEqual(decision, .immediate, "an already-loaded model should skip warmup entirely")
    }

    runSuite("DictationSession.StartPathDecision — loaded model wins over a stale failure") {
        let decision = DictationSession.StartPathDecision.decide(
            isRecordingModelLoaded: true,
            recordingModelLoadFailed: true
        )
        assertEqual(decision, .immediate, "isRecordingModelLoaded should be checked first")
    }

    runSuite("DictationSession.StartPathDecision — a model still loading or downloading records now") {
        let decision = DictationSession.StartPathDecision.decide(
            isRecordingModelLoaded: false,
            recordingModelLoadFailed: false
        )
        assertEqual(
            decision,
            .concurrentWarmupThenImmediate,
            "a cached, loading, or first-run downloading model should open the mic now and load concurrently; the stop path waits for it"
        )
    }

    runSuite("DictationSession.StartPathDecision — a failed load retries before recording") {
        let decision = DictationSession.StartPathDecision.decide(
            isRecordingModelLoaded: false,
            recordingModelLoadFailed: true
        )
        assertEqual(
            decision,
            .fullWarmupRequired,
            "a failed model load should retry and show its error before opening the mic"
        )
    }

    runSuite("DictationSession.WaitStatus — snapshots compare by value") {
        let a = DictationSession.WaitStatus(
            elapsed: 1.5,
            deviceName: "MacBook Pro Microphone",
            isRecovering: false,
            inputFormatReady: true,
            startAttempts: 2
        )
        let b = DictationSession.WaitStatus(
            elapsed: 1.5,
            deviceName: "MacBook Pro Microphone",
            isRecovering: false,
            inputFormatReady: true,
            startAttempts: 2
        )
        assertEqual(a, b, "identical wait-loop snapshots should compare equal so the controller can diff updates")
    }
}
