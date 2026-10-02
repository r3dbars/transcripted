// ParakeetZombieEngineRecoverySequenceTests.swift
// The bounded zombie-engine retry runs its steps in a safe order, stops as soon
// as stop or a route change takes the graph, and ends with one terminal result.
// The steps are fakes; this is ordering proof, not CoreAudio proof.

import Foundation

@MainActor
private final class ZombieRecoveryHarness {
    var state = ParakeetZombieRecoveryState()
    var events: [String] = []
    var terminals: [ParakeetZombieRecoveryTerminal] = []
    var graphGeneration = 1
    let engine = NSObject()
    var startGeneration: UInt64?
    var recreateSucceeds = true
    var restartSucceeds = true
    var onPublishIdle: () -> Void = {}
    var onSettle: () throws -> Void = {}
    var onRestart: () -> Void = {}

    func detect(_ failureKind: String) -> UInt64? {
        ParakeetZombieEngineRecoverySequence.admit(&state, failureKind: failureKind)
    }

    func run(_ generation: UInt64) async {
        await ParakeetZombieEngineRecoverySequence.run(generation: generation, steps: steps())
    }

    private func steps() -> ParakeetZombieEngineRecoverySteps {
        ParakeetZombieEngineRecoverySteps(
            isCurrent: { self.state.canContinue(generation: $0) },
            advance: { stage, generation in
                let advanced = self.state.advance(to: stage, generation: generation)
                if advanced { self.events.append("stage:\(stage.rawValue)") }
                return advanced
            },
            captureGraphOwner: {
                ParakeetAudioGraphOwnerToken(generation: self.graphGeneration, engine: self.engine)
            },
            publishIdle: {
                self.events.append("idle")
                self.onPublishIdle()
            },
            canContinue: { generation, owner in
                ParakeetZombieRecoveryOwnershipPolicy.canContinue(
                    taskIsCancelled: Task.isCancelled,
                    recoveryIsCurrent: self.state.canContinue(generation: generation),
                    expectedOwner: owner,
                    currentGraphGeneration: self.graphGeneration,
                    currentEngine: self.engine
                )
            },
            recreateGraph: { _, _ in
                self.events.append("recreate")
                return self.recreateSucceeds
            },
            settle: {
                self.events.append("settle")
                try self.onSettle()
            },
            restartRecording: { generation in
                self.startGeneration = generation
                let owned = ParakeetZombieEngineRecoverySequence.recordingStartKeepsRecovery(
                    startGeneration: self.startGeneration,
                    state: self.state
                )
                self.events.append("restart(own start: \(owned))")
                self.onRestart()
                return self.restartSucceeds
            },
            clearStartGeneration: { generation in
                if self.startGeneration == generation { self.startGeneration = nil }
            },
            reportRestartOutcome: { self.events.append("outcome:\($0)") },
            interruptPreservingRecoveredTimeline: { self.events.append("interrupt") },
            finish: { generation, result in
                guard let terminal = self.state.finish(result: result, generation: generation) else { return }
                self.terminals.append(terminal)
                self.events.append("finish:\(result.rawValue)")
            }
        )
    }

    /// What stop or a config change does: take the graph and cancel the attempt.
    func takeGraphAndCancel() {
        graphGeneration += 1
        if let terminal = state.cancelActiveAttempt() {
            terminals.append(terminal)
            events.append("cancelled by owner")
        }
    }
}

@MainActor
func testParakeetZombieEngineRecoverySequence() async {
    await runSuite("Zombie recovery goes idle, replaces the graph, settles, then restarts once as its own start") {
        let harness = ZombieRecoveryHarness()
        guard let generation = harness.detect("no_sample_callbacks") else {
            assertTrue(false, "the first detection should start a recovery")
            return
        }
        await harness.run(generation)

        assertEqual(
            harness.events,
            [
                "stage:reset", "idle", "recreate",
                "stage:settle", "settle",
                "stage:restart", "restart(own start: true)",
                "outcome:true", "finish:succeeded",
            ],
            "recording must be idle before the stale graph is replaced, and the route must settle before the one restart"
        )
        assertEqual(harness.terminals.count, 1, "one attempt reports exactly one result")
        assertEqual(harness.terminals.first?.stage, .restart, "success is reported from the restart stage")
        assertNil(harness.startGeneration, "the recovery's start marker is cleared once the restart returns")
        assertFalse(harness.state.isActive, "the attempt is consumed")
    }

    await runSuite("Stop or a route change while recovery goes idle keeps it out of graph recreation") {
        let harness = ZombieRecoveryHarness()
        guard let generation = harness.detect("no_sample_callbacks") else { return }
        harness.onPublishIdle = { harness.takeGraphAndCancel() }
        await harness.run(generation)

        assertFalse(harness.events.contains("recreate"), "a cancelled recovery must not touch the graph the canceller now owns")
        assertFalse(harness.events.contains { $0.hasPrefix("restart") }, "a cancelled recovery never restarts the mic")
        assertEqual(harness.terminals.map(\.result), [.cancelled], "only the canceller's terminal result is reported")
    }

    await runSuite("A newer graph owner stops recovery even when the attempt is still current") {
        let harness = ZombieRecoveryHarness()
        guard let generation = harness.detect("silent_hfp_callbacks") else { return }
        harness.onPublishIdle = { harness.graphGeneration += 1 }
        await harness.run(generation)

        assertFalse(harness.events.contains("recreate"), "recreation is gated on the exact graph owner, not just the attempt")
        assertEqual(harness.terminals.map(\.result), [.failed], "the abandoned attempt still ends with one terminal result")
        assertEqual(harness.terminals.first?.stage, .reset, "it ended in the reset stage")
        assertEqual(harness.terminals.first?.failureKind, "silent_hfp_callbacks", "the detection kind is kept for telemetry")
    }

    await runSuite("A failed graph replacement ends the attempt without settling or restarting") {
        let harness = ZombieRecoveryHarness()
        guard let generation = harness.detect("no_sample_callbacks") else { return }
        harness.recreateSucceeds = false
        await harness.run(generation)

        assertEqual(harness.events, ["stage:reset", "idle", "recreate", "finish:failed"], "no settle or restart after a refused replacement")
    }

    await runSuite("Cancellation during the settle delay never restarts the mic") {
        let harness = ZombieRecoveryHarness()
        guard let generation = harness.detect("no_sample_callbacks") else { return }
        harness.onSettle = {
            harness.takeGraphAndCancel()
            throw CancellationError()
        }
        await harness.run(generation)

        assertFalse(harness.events.contains { $0.hasPrefix("restart") }, "a settle cut short by cancellation must not restart")
        assertEqual(harness.terminals.map(\.result), [.cancelled], "the attempt ends once, as cancelled")
    }

    await runSuite("A failed restart surfaces the interruption and reports failure once") {
        let harness = ZombieRecoveryHarness()
        guard let generation = harness.detect("no_sample_callbacks") else { return }
        harness.restartSucceeds = false
        await harness.run(generation)

        assertEqual(
            Array(harness.events.suffix(3)),
            ["outcome:false", "interrupt", "finish:failed"],
            "the session hears about the interruption before the failure is reported"
        )
        assertEqual(harness.terminals.count, 1, "the failure is reported once")
        assertEqual(harness.terminals.first?.stage, .restart, "it failed in the restart stage")
    }

    await runSuite("A restart that returns after the attempt was cancelled reports nothing more") {
        let harness = ZombieRecoveryHarness()
        guard let generation = harness.detect("no_sample_callbacks") else { return }
        harness.onRestart = { harness.takeGraphAndCancel() }
        await harness.run(generation)

        assertFalse(harness.events.contains { $0.hasPrefix("outcome") }, "a superseded restart's result is ignored")
        assertFalse(harness.events.contains("interrupt"), "a superseded restart must not interrupt the new owner")
        assertEqual(harness.terminals.map(\.result), [.cancelled], "only the cancellation is reported")
        assertNil(harness.startGeneration, "the stale start marker is still cleared")
    }

    runSuite("A second zombie detection while recovery runs does not start another attempt") {
        var state = ParakeetZombieRecoveryState()
        let first = ParakeetZombieEngineRecoverySequence.admit(&state, failureKind: "no_sample_callbacks")
        let second = ParakeetZombieEngineRecoverySequence.admit(&state, failureKind: "silent_hfp_callbacks")
        assertNotNil(first, "the first detection starts a recovery")
        assertNil(second, "a duplicate detector callback must not replace the active attempt")
        let terminal = first.flatMap { state.finish(result: .failed, generation: $0) }
        assertEqual(terminal?.failureKind, "no_sample_callbacks", "the active attempt keeps its own detection kind")
        assertNotNil(
            ParakeetZombieEngineRecoverySequence.admit(&state, failureKind: "silent_hfp_callbacks"),
            "a later zombie can recover once the previous attempt ended"
        )
    }

    runSuite("A recording start cancels zombie recovery unless it is that recovery's own restart") {
        var state = ParakeetZombieRecoveryState()
        guard let generation = ParakeetZombieEngineRecoverySequence.admit(&state, failureKind: "no_sample_callbacks") else {
            assertTrue(false, "detection should start a recovery")
            return
        }
        assertTrue(
            ParakeetZombieEngineRecoverySequence.recordingStartKeepsRecovery(startGeneration: generation, state: state),
            "the recovery's own restart must not cancel the task running it"
        )
        assertFalse(
            ParakeetZombieEngineRecoverySequence.recordingStartKeepsRecovery(startGeneration: nil, state: state),
            "a user start during recovery takes over and cancels it"
        )
        _ = state.cancelActiveAttempt()
        assertFalse(
            ParakeetZombieEngineRecoverySequence.recordingStartKeepsRecovery(startGeneration: generation, state: state),
            "a marker left from a finished attempt preserves nothing"
        )
    }
}
