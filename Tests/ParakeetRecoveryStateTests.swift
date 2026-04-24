// ParakeetRecoveryStateTests.swift
// Tests for the device-change recovery state machine — generation guard,
// readiness flags, transitions across config-change → recovery → success.

import Foundation

func testParakeetRecoveryState() {
    runSuite("ParakeetRecoveryState — initial state is ready and not recovering") {
        let state = ParakeetRecoveryState()
        assertFalse(state.isRecovering, "fresh state should not be recovering")
        assertTrue(state.inputFormatReady, "fresh state should report format ready")
        assertEqual(state.generation, 0, "fresh state should be generation 0")
    }

    runSuite("ParakeetRecoveryState.beginConfigChange — enters recovery and bumps generation") {
        var state = ParakeetRecoveryState()
        let g = state.beginConfigChange()

        assertEqual(g, 1, "first config change should be generation 1")
        assertTrue(state.isRecovering, "config change should mark recovery active")
        assertFalse(state.inputFormatReady, "config change should clear format-ready")
        assertEqual(state.generation, 1, "generation should be advanced")
    }

    runSuite("ParakeetRecoveryState.finishRecovery — success clears flags for matching generation") {
        var state = ParakeetRecoveryState()
        let g = state.beginConfigChange()
        let applied = state.finishRecovery(success: true, generation: g)

        assertTrue(applied, "matching generation should apply")
        assertFalse(state.isRecovering, "successful finish should clear recovery flag")
        assertTrue(state.inputFormatReady, "successful finish should mark format ready")
    }

    runSuite("ParakeetRecoveryState.finishRecovery — failure clears recovery but leaves format unready") {
        var state = ParakeetRecoveryState()
        let g = state.beginConfigChange()
        let applied = state.finishRecovery(success: false, generation: g)

        assertTrue(applied, "matching generation should apply")
        assertFalse(state.isRecovering, "failed finish should clear recovery flag")
        assertFalse(state.inputFormatReady, "failed finish should leave format unready")
    }

    runSuite("ParakeetRecoveryState.finishRecovery — stale generation is rejected") {
        var state = ParakeetRecoveryState()
        let firstGen = state.beginConfigChange()
        _ = state.beginConfigChange()  // newer device change supersedes
        let applied = state.finishRecovery(success: true, generation: firstGen)

        assertFalse(applied, "stale finish should be rejected")
        assertTrue(state.isRecovering, "newer recovery should still be active")
        assertFalse(state.inputFormatReady, "format should still be unready after stale finish")
    }

    runSuite("ParakeetRecoveryState.timeoutRecovery — fails active recovery and supersedes stale tasks") {
        var state = ParakeetRecoveryState()
        let recoveryGeneration = state.beginConfigChange()
        let applied = state.timeoutRecovery(generation: recoveryGeneration)

        assertTrue(applied, "matching active recovery should time out")
        assertFalse(state.isRecovering, "timeout should clear active recovery")
        assertFalse(state.inputFormatReady, "timeout should leave input unready for prewarm")
        assertTrue(state.isStale(generation: recoveryGeneration), "timeout should supersede the stuck recovery generation")
    }

    runSuite("ParakeetRecoveryState.timeoutRecovery — ignores stale or finished recovery") {
        var state = ParakeetRecoveryState()
        let recoveryGeneration = state.beginConfigChange()
        _ = state.finishRecovery(success: true, generation: recoveryGeneration)

        assertFalse(state.timeoutRecovery(generation: recoveryGeneration), "finished recovery should not time out later")
        assertTrue(state.inputFormatReady, "finished recovery should keep its ready state")
    }

    runSuite("ParakeetRecoveryState.timeoutRecovery — rejects superseded generations") {
        var state = ParakeetRecoveryState()
        let staleGeneration = state.beginConfigChange()
        _ = state.beginConfigChange()

        assertFalse(state.timeoutRecovery(generation: staleGeneration), "stale timeout should not affect newer recovery")
        assertTrue(state.isRecovering, "newer recovery should stay active")
        assertFalse(state.inputFormatReady, "newer recovery should keep input unready")
    }

    runSuite("ParakeetRecoveryState.timeoutRecovery — ignores pristine state") {
        var state = ParakeetRecoveryState()

        assertFalse(state.timeoutRecovery(generation: 0), "fresh non-recovering state should not time out")
        assertFalse(state.isRecovering, "fresh state should remain not recovering")
        assertTrue(state.inputFormatReady, "fresh state should remain ready")
    }

    runSuite("ParakeetRecoveryState.finishRecovery — timeout supersedes late success") {
        var state = ParakeetRecoveryState()
        let recoveryGeneration = state.beginConfigChange()
        _ = state.timeoutRecovery(generation: recoveryGeneration)

        assertFalse(state.finishRecovery(success: true, generation: recoveryGeneration), "late recovery success should stay stale after timeout")
        assertFalse(state.isRecovering, "timed-out state should remain not recovering")
        assertFalse(state.inputFormatReady, "late success should not mark timed-out input ready")
    }

    runSuite("ParakeetRecoveryState.isStale — detects superseded generations") {
        var state = ParakeetRecoveryState()
        let g1 = state.beginConfigChange()
        assertFalse(state.isStale(generation: g1), "current generation is not stale")

        _ = state.beginConfigChange()
        assertTrue(state.isStale(generation: g1), "earlier generation is stale once superseded")
    }

    runSuite("ParakeetRecoveryState.markFormatReady — clears recovery and marks format ready without bumping generation") {
        var state = ParakeetRecoveryState()
        let g = state.beginConfigChange()
        state.markFormatReady()

        assertFalse(state.isRecovering, "markFormatReady should clear recovery flag")
        assertTrue(state.inputFormatReady, "markFormatReady should mark format ready")
        assertEqual(state.generation, g, "markFormatReady should not bump generation")
    }

    runSuite("ParakeetRecoveryState.markFormatUnready — flips format flag without bumping generation") {
        var state = ParakeetRecoveryState()
        let before = state.generation
        state.markFormatUnready()

        assertFalse(state.inputFormatReady, "format should be unready after explicit mark")
        assertEqual(state.generation, before, "marking format unready should not bump generation")
        assertFalse(state.isRecovering, "marking format unready alone should not set recovery flag")
    }

    runSuite("ParakeetRecoveryState.canStartRecording — requires recovery to be done and format ready") {
        var state = ParakeetRecoveryState()
        assertTrue(state.canStartRecording, "fresh state should allow recording starts")

        let generation = state.beginConfigChange()
        assertFalse(state.canStartRecording, "active recovery should block recording starts")

        _ = state.finishRecovery(success: true, generation: generation)
        assertTrue(state.canStartRecording, "successful recovery should allow recording starts again")

        state.markStartFailed()
        assertFalse(state.canStartRecording, "start failure should hold recording until prewarm marks format ready")
    }

    runSuite("ParakeetRecoveryState.markStartFailed — does not bump generation or enter recovery") {
        var state = ParakeetRecoveryState()
        let before = state.generation
        state.markStartFailed()

        assertFalse(state.inputFormatReady, "start failure should mark format unready")
        assertFalse(state.isRecovering, "plain start failure should not pretend a device-change recovery is active")
        assertEqual(state.generation, before, "plain start failure should not supersede device-change generations")
    }

    runSuite("ParakeetRecoveryState.markStartFailed — preserves active recovery generation") {
        var state = ParakeetRecoveryState()
        let generation = state.beginConfigChange()

        state.markStartFailed()

        assertTrue(state.isRecovering, "start failure during device recovery should keep recovery visible")
        assertFalse(state.inputFormatReady, "start failure should keep the input format unready")
        assertEqual(state.generation, generation, "start failure should not supersede the active recovery generation")
    }

    runSuite("ParakeetRecoveryState.markFormatReady — recovers after start failure") {
        var state = ParakeetRecoveryState()
        state.markStartFailed()

        state.markFormatReady()

        assertTrue(state.canStartRecording, "format-ready should unblock recording after a failed start")
    }

    runSuite("ParakeetAudioStartRecoveryPolicy.shouldRetryStartFailure — retries only normal first failures") {
        assertTrue(
            ParakeetAudioStartRecoveryPolicy.shouldRetryStartFailure(isRecoveryAttempt: false, failedAttempts: 1, retryBudget: 1),
            "normal first failure should get one immediate graph-reset retry"
        )
        assertFalse(
            ParakeetAudioStartRecoveryPolicy.shouldRetryStartFailure(isRecoveryAttempt: false, failedAttempts: 2, retryBudget: 1),
            "retry budget should cap repeated immediate attempts"
        )
        assertFalse(
            ParakeetAudioStartRecoveryPolicy.shouldRetryStartFailure(isRecoveryAttempt: true, failedAttempts: 1, retryBudget: 1),
            "recovery attempts should not recursively retry"
        )
    }

    runSuite("ParakeetAudioStartRecoveryPolicy.shouldReportFailure — throttles repeated Sentry reports") {
        assertTrue(
            ParakeetAudioStartRecoveryPolicy.shouldReportFailure(now: 100, lastReportAt: nil, throttle: 15),
            "first failure should report"
        )
        assertFalse(
            ParakeetAudioStartRecoveryPolicy.shouldReportFailure(now: 110, lastReportAt: 100, throttle: 15),
            "repeat failures inside the throttle window should stay local-only"
        )
        assertTrue(
            ParakeetAudioStartRecoveryPolicy.shouldReportFailure(now: 116, lastReportAt: 100, throttle: 15),
            "failures after the throttle window should report again"
        )
    }
}
