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
            selectedModelFilesAvailableLocally: false
        )
        assertEqual(decision, .immediate, "an already-loaded model should skip warmup entirely")
    }

    runSuite("DictationSession.StartPathDecision — loaded model wins even when files are also available") {
        let decision = DictationSession.StartPathDecision.decide(
            isRecordingModelLoaded: true,
            selectedModelFilesAvailableLocally: true
        )
        assertEqual(decision, .immediate, "isRecordingModelLoaded should be checked first")
    }

    runSuite("DictationSession.StartPathDecision — files on disk warm up concurrently") {
        let decision = DictationSession.StartPathDecision.decide(
            isRecordingModelLoaded: false,
            selectedModelFilesAvailableLocally: true
        )
        assertEqual(
            decision,
            .concurrentWarmupThenImmediate,
            "on-disk model files should open the mic now and load concurrently instead of blocking on warmup"
        )
    }

    runSuite("DictationSession.StartPathDecision — neither loaded nor cached requires full warmup") {
        let decision = DictationSession.StartPathDecision.decide(
            isRecordingModelLoaded: false,
            selectedModelFilesAvailableLocally: false
        )
        assertEqual(
            decision,
            .fullWarmupRequired,
            "a cold model with nothing on disk should wait out the full warmup before opening the mic"
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
