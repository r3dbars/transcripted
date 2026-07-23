// ParakeetRecoveryStateTests.swift
// Device-change recovery, route debounce, zombie lifecycle, and retry policy.
// Audio graph ownership and system-input interleavings live in their own suite.

import Foundation

func testParakeetRecoveryState() async {
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

    runSuite("ParakeetRecoveryState.finishRecovery — stale failure cannot poison newer ready generation") {
        var state = ParakeetRecoveryState()
        let staleGeneration = state.beginConfigChange()
        let currentGeneration = state.beginConfigChange()

        assertTrue(state.finishRecovery(success: true, generation: currentGeneration), "current recovery should mark the graph ready")
        assertFalse(state.finishRecovery(success: false, generation: staleGeneration), "stale failure must be rejected")
        assertTrue(state.canStartRecording, "late failure from an old graph must not poison the ready graph")
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

    runSuite("ParakeetRecoveryState.timeoutRecovery — stale timeout cannot poison newer ready generation") {
        var state = ParakeetRecoveryState()
        let staleGeneration = state.beginConfigChange()
        let currentGeneration = state.beginConfigChange()

        assertTrue(state.finishRecovery(success: true, generation: currentGeneration), "current recovery should mark input ready")
        assertFalse(state.timeoutRecovery(generation: staleGeneration), "stale timeout must not apply after newer success")
        assertTrue(state.canStartRecording, "late timeout from an old graph must not block recording")
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

    runSuite("ParakeetRecoveryState.reset — clears cancellation leftovers and supersedes older recovery tasks") {
        var state = ParakeetRecoveryState()
        let staleGeneration = state.beginConfigChange()

        state.reset()

        assertFalse(state.isRecovering, "reset should clear recovering state")
        assertTrue(state.inputFormatReady, "reset should restore ready state for a fresh start")
        assertTrue(state.canStartRecording, "reset should allow a new start attempt")
        assertTrue(state.isStale(generation: staleGeneration), "reset should supersede in-flight recovery tasks")
    }

    runSuite("ParakeetRecoveryState.cancelRecovery — stop cancels only its matching recovery") {
        var state = ParakeetRecoveryState()
        let recoveryGeneration = state.beginConfigChange()

        assertTrue(
            state.cancelRecovery(generation: recoveryGeneration),
            "the stop that observed the current recovery should consume it"
        )
        assertTrue(state.canStartRecording, "cancelling recovery should unblock the next recording start")
        assertTrue(
            state.isStale(generation: recoveryGeneration),
            "the suspended cleanup must become stale before it can resume"
        )
    }

    runSuite("ParakeetRecoveryState.cancelRecovery — stale cleanup preserves a successor owner") {
        var state = ParakeetRecoveryState()
        let staleGeneration = state.beginConfigChange()
        let successorGeneration = state.beginConfigChange()

        assertFalse(
            state.cancelRecovery(generation: staleGeneration),
            "a cleanup from the retired generation must not cancel its successor"
        )
        assertTrue(state.isRecovering, "the successor recovery should remain active")
        assertFalse(state.canStartRecording, "the successor must still gate recording starts")
        assertTrue(
            state.finishRecovery(success: true, generation: successorGeneration),
            "the successor should retain the right to finish"
        )
    }

    runSuite("ParakeetRecoveryState.cancelRecovery — late timeout cannot poison a cancelled stop") {
        var state = ParakeetRecoveryState()
        let recoveryGeneration = state.beginConfigChange()

        assertTrue(state.cancelRecovery(generation: recoveryGeneration), "matching stop should cancel recovery")
        assertFalse(
            state.timeoutRecovery(generation: recoveryGeneration),
            "the old timeout must not make the next start unready"
        )
        assertTrue(state.canStartRecording, "a cancelled timeout should leave the next start available")
    }

    runSuite("ParakeetRouteTransitionDebounceState emits one stable categorical transition") {
        let builtIn = categoricalRoute(input: "built_in", output: "built_in", shape: "built_in_to_built_in")
        let bluetooth = categoricalRoute(input: "bluetooth", output: "bluetooth", shape: "bluetooth_to_bluetooth")
        var state = ParakeetRouteTransitionDebounceState()
        state.seedStableRouteIfNeeded(builtIn)

        state.observe(bluetooth)
        state.observe(bluetooth)
        let transition = state.commitPendingRoute()

        assertEqual(transition, bluetooth, "repeated notifications should coalesce into one stable route transition")
        assertEqual(state.commitPendingRoute(), nil, "a committed burst should not emit a second transition")

        state.observe(bluetooth)
        assertEqual(state.commitPendingRoute(), nil, "the already-stable route should stay quiet")
    }

    runSuite("ParakeetRouteTransitionDebounceState suppresses oscillation back to the original route") {
        let builtIn = categoricalRoute(input: "built_in", output: "built_in", shape: "built_in_to_built_in")
        let bluetooth = categoricalRoute(input: "bluetooth", output: "bluetooth", shape: "bluetooth_to_bluetooth")
        var state = ParakeetRouteTransitionDebounceState()
        state.seedStableRouteIfNeeded(builtIn)

        state.observe(bluetooth)
        state.observe(builtIn)

        assertEqual(state.commitPendingRoute(), nil, "A -> B -> A notification churn is not a stable route change")
        assertEqual(state.stableRoute, builtIn, "oscillation should preserve the original stable route")
    }

    runSuite("ParakeetRouteTransitionDebounceState treats the first known route as a baseline") {
        let builtIn = categoricalRoute(input: "built_in", output: "built_in", shape: "built_in_to_built_in")
        var state = ParakeetRouteTransitionDebounceState()

        state.observe(builtIn)

        assertEqual(state.commitPendingRoute(), nil, "initial discovery should seed a baseline instead of claiming a transition")
        assertEqual(state.stableRoute, builtIn, "initial discovery should become the stable baseline")
    }

    runSuite("ParakeetZombieRecoveryState emits exactly one terminal result per attempt") {
        var state = ParakeetZombieRecoveryState()
        let generation = state.begin(failureKind: "no_sample_callbacks")

        assertTrue(state.advance(to: .reset, generation: generation), "active recovery should advance into reset")
        assertTrue(state.advance(to: .restart, generation: generation), "active recovery should advance into restart")
        let terminal = state.finish(result: .failed, generation: generation)

        assertEqual(terminal?.stage, .restart, "terminal telemetry should preserve the last actionable stage")
        assertEqual(terminal?.result, .failed, "terminal telemetry should preserve the outcome")
        assertEqual(terminal?.failureKind, "no_sample_callbacks", "terminal telemetry should preserve the categorical trigger")
        assertEqual(state.finish(result: .failed, generation: generation), nil, "the same attempt cannot finish twice")
    }

    runSuite("ParakeetZombieRecoveryState cancellation is terminal and rejects stale callbacks") {
        var state = ParakeetZombieRecoveryState()
        let generation = state.begin(failureKind: "silent_hfp_callbacks")
        assertTrue(state.advance(to: .settle, generation: generation), "active recovery should advance into settle")

        let terminal = state.cancelActiveAttempt()

        assertEqual(terminal?.stage, .settle, "cancellation should name the stage it interrupted")
        assertEqual(terminal?.result, .cancelled, "cancellation should have a categorical terminal result")
        assertFalse(state.canContinue(generation: generation), "cancelled work should become stale")
        assertFalse(state.advance(to: .restart, generation: generation), "late callbacks cannot revive a cancelled recovery")
    }

    await runSuite("Parakeet user stop invalidates recovery before a delayed restart") {
        let harness = ParakeetZombieStopInterleavingHarness()
        let resetPublished = ParakeetAsyncInterleavingGate()
        let allowDelayedRestart = ParakeetAsyncInterleavingGate()

        let delayedRecovery = Task {
            let generation = await harness.beginReset()
            await resetPublished.open()
            await allowDelayedRestart.wait()
            return await harness.tryRestart(generation: generation)
        }

        await resetPublished.wait()
        let terminal = await harness.stop()
        await allowDelayedRestart.open()

        assertEqual(terminal?.result, .cancelled, "stop should consume the active recovery attempt")
        assertFalse(
            await delayedRecovery.value,
            "a recovery continuation delayed behind stop must not restart the microphone"
        )
    }

    runSuite("ParakeetZombieRecoveryState keeps one active generation") {
        var state = ParakeetZombieRecoveryState()
        let first = state.begin(failureKind: "no_sample_callbacks")
        let duplicate = state.begin(failureKind: "silent_hfp_callbacks")

        assertEqual(duplicate, first, "a second detector callback must not replace an unfinished recovery attempt")
        assertTrue(state.canContinue(generation: first), "the original attempt should remain active")
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

private actor ParakeetZombieStopInterleavingHarness {
    private var state = ParakeetZombieRecoveryState()

    func beginReset() -> UInt64 {
        let generation = state.begin(failureKind: "no_sample_callbacks")
        _ = state.advance(to: .reset, generation: generation)
        return generation
    }

    func stop() -> ParakeetZombieRecoveryTerminal? {
        state.cancelActiveAttempt()
    }

    func tryRestart(generation: UInt64) -> Bool {
        state.advance(to: .restart, generation: generation)
    }
}

private func categoricalRoute(
    input: String,
    output: String,
    shape: String
) -> ParakeetCategoricalAudioRoute {
    ParakeetCategoricalAudioRoute(
        inputDeviceClass: input,
        outputDeviceClass: output,
        routeShape: shape
    )
}
