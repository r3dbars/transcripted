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

    runSuite("ParakeetRecoveryState.isStale — detects superseded generations") {
        var state = ParakeetRecoveryState()
        let g1 = state.beginConfigChange()
        assertFalse(state.isStale(generation: g1), "current generation is not stale")

        _ = state.beginConfigChange()
        assertTrue(state.isStale(generation: g1), "earlier generation is stale once superseded")
    }

    runSuite("ParakeetRecoveryState.markFormatUnready — flips format flag without bumping generation") {
        var state = ParakeetRecoveryState()
        let before = state.generation
        state.markFormatUnready()

        assertFalse(state.inputFormatReady, "format should be unready after explicit mark")
        assertEqual(state.generation, before, "marking format unready should not bump generation")
        assertFalse(state.isRecovering, "marking format unready alone should not set recovery flag")
    }
}
