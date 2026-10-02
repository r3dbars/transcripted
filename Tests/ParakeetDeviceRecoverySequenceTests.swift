// ParakeetDeviceRecoverySequenceTests.swift
// Device-change recovery keeps recording intent across a Bluetooth burst,
// waits out AUHAL binding, never commits a stale or cancelled snapshot, and
// never rebuilds a graph that its own interruption publication handed to
// someone else. The steps are fakes over the real ParakeetRecoveryState; this
// is ordering proof, not CoreAudio or AirPods proof (`bash check.sh hardware`).

import Foundation

private struct FakeRecoverySnapshot {
    var readiness: ParakeetAudioFormatReadiness = .ready
    var sampleRate: Double = 24_000
}

private struct FakeRewarmError: Error {}

@MainActor
private final class DeviceRecoveryHarness {
    var state = ParakeetRecoveryState()
    /// The engine's `configChangeWasRecording`.
    var intent = false
    var isRecording = false
    var events: [String] = []
    var sleeps: [UInt64] = []
    var readAttempts: [Int] = []
    var finished: [String] = []
    var graphGeneration = 1
    let engine = NSObject()
    let queue = NSObject()
    var hasRecoveredTimeline = true
    var restartOutcome: ParakeetRouteRecoveryRestartOutcome = .restarted(attempt: 1)
    /// Scripted snapshot reads, in order; a ready snapshot once they run out.
    var reads: [Result<FakeRecoverySnapshot, Error>] = []
    var onRead: (_ attempt: Int) -> Void = { _ in }
    var onSleep: () -> Void = {}
    var onPublish: () -> Void = {}
    var onInterrupt: () -> Void = {}

    /// What the route-change host does on each notification: latch intent
    /// while recording, never clear it, and start a newer generation.
    func notify() -> UInt64 {
        if isRecording { intent = true }
        return state.beginConfigChange()
    }

    /// What `attemptDeviceRecovery` does: read the latched intent, then run.
    func attempt(_ generation: UInt64) async {
        await ParakeetDeviceRecoverySequence.run(
            generation: generation,
            shouldRestartRecording: intent,
            steps: steps()
        )
    }

    func timeout(_ generation: UInt64, wasRecording: Bool) async {
        await ParakeetDeviceRecoverySequence.runTimeout(
            generation: generation,
            wasRecording: wasRecording,
            steps: timeoutSteps()
        )
    }

    var owner: ParakeetAudioEngineQueueOwnerToken {
        ParakeetAudioEngineQueueOwnerToken(generation: graphGeneration, engine: engine, queue: queue)
    }

    private func graphSteps() -> ParakeetDeviceRecoveryGraphSteps {
        ParakeetDeviceRecoveryGraphSteps(
            currentOwner: { self.owner },
            ownsQueue: { $0 == self.owner },
            rebuildOnQueue: { reason in
                self.events.append("rebuild:\(reason)")
                return true
            },
            abandonBlockedGraph: { reason, owner in
                guard owner == self.owner else { return false }
                self.events.append("abandon:\(reason)")
                return true
            },
            scheduleFreshPrewarmRetry: { self.events.append("prewarm") }
        )
    }

    private func steps() -> ParakeetDeviceRecoverySteps<FakeRecoverySnapshot> {
        ParakeetDeviceRecoverySteps(
            isStale: { self.state.isStale(generation: $0) },
            releaseRecordingIntent: {
                self.intent = false
                self.events.append("releaseIntent")
            },
            reportAttempted: { _ in self.events.append("attempted") },
            reportFinished: { result, _ in self.finished.append(result) },
            readSnapshot: { _, attempt in
                self.readAttempts.append(attempt)
                self.onRead(attempt)
                if self.reads.isEmpty { return FakeRecoverySnapshot() }
                return try self.reads.removeFirst().get()
            },
            readiness: { $0.readiness },
            reportStillSettling: { _, _, attempt in self.events.append("settling:\(attempt)") },
            sleep: { nanoseconds in
                self.sleeps.append(nanoseconds)
                self.onSleep()
            },
            commitSnapshot: { self.events.append("commit:\(Int($0.sampleRate))") },
            finishRecovery: { success, generation in
                let finished = self.state.finishRecovery(success: success, generation: generation)
                if finished { self.events.append("finishRecovery:\(success)") }
                return finished
            },
            cancelTimeout: { self.events.append("cancelTimeout") },
            publishRecoveryState: {
                self.events.append("publish")
                self.onPublish()
            },
            reportSucceeded: { _ in self.events.append("succeeded") },
            restartRecording: {
                self.events.append("restart")
                return self.restartOutcome
            },
            reportRecordingRecovered: { self.events.append("recovered:\($0)") },
            interruptPreservingTimeline: {
                self.events.append("interrupt")
                self.onInterrupt()
            },
            reportRestartExhausted: { _ in self.events.append("exhausted") },
            hasRecoveredTimeline: { self.hasRecoveredTimeline },
            reportFailed: { _ in self.events.append("failed") },
            reportRecordingInterrupted: { _ in self.events.append("reportInterrupted") },
            reportRewarmFailed: { _, sentry in self.events.append("rewarmFailed(sentry: \(sentry))") },
            graph: graphSteps()
        )
    }

    private func timeoutSteps() -> ParakeetDeviceRecoveryTimeoutSteps {
        ParakeetDeviceRecoveryTimeoutSteps(
            timeoutRecovery: { self.state.timeoutRecovery(generation: $0) },
            clearTimeoutTask: { self.events.append("clearTimeoutTask") },
            releaseRecordingIntent: {
                self.intent = false
                self.events.append("releaseIntent")
            },
            publishRecoveryState: {
                self.events.append("publish")
                self.onPublish()
            },
            reportTimedOut: { self.events.append("timedOut(sentry: \($0.reportSentryFailure))") },
            interruptPreservingTimeline: {
                self.events.append("interrupt")
                self.onInterrupt()
            },
            reportRecordingInterrupted: { self.events.append("reportInterrupted") },
            graph: graphSteps()
        )
    }
}

@MainActor
func testParakeetDeviceRecoverySequence() async {
    await runIntentSuites()
    await runBindingAndCommitSuites()
    await runFailureAndTimeoutSuites()
}

// MARK: - Recording intent

@MainActor
private func runIntentSuites() async {
    await runSuite("A Bluetooth notification burst keeps recording intent for the recovery that finishes") {
        let harness = DeviceRecoveryHarness()
        harness.isRecording = true
        let first = harness.notify()
        // The system stopped the engine before posting; teardown marks the
        // take stopped, so the next notification arrives with recording off.
        harness.isRecording = false

        var second: UInt64 = 0
        harness.onRead = { _ in
            harness.onRead = { _ in }
            second = harness.notify()
        }
        await harness.attempt(first)

        assertTrue(harness.intent, "a superseded recovery must leave the newer recovery's intent armed")
        assertFalse(harness.events.contains("releaseIntent"), "a stale task never releases intent")
        assertFalse(harness.events.contains { $0.hasPrefix("commit") }, "the superseded snapshot commits nothing")
        assertFalse(harness.events.contains("restart"), "the superseded recovery doesn't restart the take")
        assertEqual(harness.finished, ["superseded"], "the superseded attempt reports one terminal result")

        harness.finished = []
        harness.events = []
        await harness.attempt(second)

        assertEqual(
            harness.events,
            ["attempted", "commit:24000", "finishRecovery:true", "cancelTimeout", "publish", "succeeded", "restart", "recovered:1", "releaseIntent"],
            "the second notification's recovery inherits intent, restarts the take, then releases intent"
        )
        assertFalse(harness.intent, "the current recovery releases intent when it ends")
        assertEqual(harness.finished, ["success"], "one terminal result")
    }

    await runSuite("Starting a recovery reads intent without clearing it") {
        let harness = DeviceRecoveryHarness()
        harness.isRecording = true
        let generation = harness.notify()
        var intentDuringRead: Bool?
        harness.onRead = { _ in intentDuringRead = harness.intent }
        await harness.attempt(generation)
        assertEqual(intentDuringRead, true, "intent stays latched while the recovery is in flight")
    }

    await runSuite("An idle recovery succeeds without restarting anything") {
        let harness = DeviceRecoveryHarness()
        let generation = harness.notify()
        await harness.attempt(generation)
        assertFalse(harness.events.contains("restart"), "nothing was recording")
        assertEqual(harness.finished, ["success"], "an idle recovery still finishes")
        assertTrue(harness.state.canStartRecording, "the input is ready again")
    }
}

// MARK: - Binding wait and snapshot commit

@MainActor
private func runBindingAndCommitSuites() async {
    await runSuite("A binding error waits and polls again instead of failing the recovery") {
        let harness = DeviceRecoveryHarness()
        let generation = harness.notify()
        harness.reads = [
            .failure(DictationInputDeviceBindingError.selectedDeviceNotBound),
            .failure(DictationInputDeviceBindingError.applicationFailed),
        ]
        await harness.attempt(generation)

        assertEqual(harness.readAttempts, [1, 2, 3], "each poll reads a fresh snapshot")
        assertEqual(
            harness.sleeps,
            [TranscriptedConstants.audioRecoveryDelay, TranscriptedConstants.audioRecoveryDelay],
            "each binding retry waits for the hardware instead of spinning"
        )
        assertTrue(harness.events.contains("commit:24000"), "the bound snapshot commits")
        assertFalse(harness.events.contains { $0.hasPrefix("rebuild") || $0.hasPrefix("abandon") }, "a binding wait never replaces the graph")
        assertFalse(harness.events.contains("failed"), "a binding wait isn't a failed recovery")
    }

    await runSuite("A binding wait stops polling once a newer route change supersedes it") {
        let harness = DeviceRecoveryHarness()
        let generation = harness.notify()
        harness.reads = [.failure(DictationInputDeviceBindingError.selectedDeviceNotBound)]
        harness.onSleep = { _ = harness.notify() }
        await harness.attempt(generation)

        assertEqual(harness.readAttempts, [1], "a superseded wait reads nothing more")
        assertFalse(harness.events.contains { $0.hasPrefix("commit") }, "nothing commits")
        assertFalse(harness.events.contains("publish"), "the newer recovery owns the published state")
        assertEqual(harness.finished, ["superseded"], "one terminal result")
    }

    await runSuite("A route that's still settling is reported and polled again") {
        let harness = DeviceRecoveryHarness()
        let generation = harness.notify()
        harness.reads = [.success(FakeRecoverySnapshot(readiness: .routeNotSettled))]
        await harness.attempt(generation)
        assertEqual(harness.readAttempts, [1, 2], "an unsettled route is read again")
        assertTrue(harness.events.contains("settling:1"), "the deferral is reported with its attempt")
        assertEqual(harness.sleeps, [TranscriptedConstants.audioRecoveryDelay], "it waits between polls")
    }

    await runSuite("A snapshot that lands after a newer route change never commits its rate") {
        let harness = DeviceRecoveryHarness()
        let generation = harness.notify()
        harness.onRead = { _ in _ = harness.notify() }
        await harness.attempt(generation)
        assertFalse(harness.events.contains { $0.hasPrefix("commit") }, "an older route's rate must not overwrite the new graph")
        assertFalse(harness.events.contains("publish"), "the stale snapshot doesn't finish recovery")
    }

    await runSuite("A cancelled snapshot never commits its rate") {
        let harness = DeviceRecoveryHarness()
        let generation = harness.notify()
        harness.onRead = { _ in withUnsafeCurrentTask { $0?.cancel() } }
        let task = Task { @MainActor in await harness.attempt(generation) }
        await task.value
        assertFalse(harness.events.contains { $0.hasPrefix("commit") }, "a cancelled snapshot must not overwrite the recording rate")
        assertEqual(harness.finished, ["cancelled"], "the cancellation is the terminal result")
        assertTrue(harness.events.contains("releaseIntent"), "a cancelled but current recovery still releases intent")
    }
}

// MARK: - Failure and timeout

@MainActor
private func runFailureAndTimeoutSuites() async {
    await runSuite("A failed recovery, an exhausted restart and a timeout each offer the partial take") {
        let failed = DeviceRecoveryHarness()
        failed.isRecording = true
        let failedGeneration = failed.notify()
        failed.reads = [.failure(FakeRewarmError())]
        await failed.attempt(failedGeneration)
        assertEqual(
            failed.events,
            [
                "attempted", "finishRecovery:false", "cancelTimeout", "publish", "failed",
                "interrupt", "reportInterrupted", "rewarmFailed(sentry: true)",
                "rebuild:device_change_rewarm_failed", "prewarm", "releaseIntent",
            ],
            "a recording whose rewarm failed is interrupted with its audio kept, then the graph is rebuilt"
        )
        assertFalse(failed.intent, "the failed recovery releases intent")

        let exhausted = DeviceRecoveryHarness()
        exhausted.isRecording = true
        exhausted.restartOutcome = .exhausted
        await exhausted.attempt(exhausted.notify())
        assertTrue(exhausted.events.contains("interrupt"), "a restart that ran out of budget keeps the partial take")
        assertEqual(exhausted.finished, ["failed"], "and reports one failure")

        let timedOut = DeviceRecoveryHarness()
        timedOut.isRecording = true
        await timedOut.timeout(timedOut.notify(), wasRecording: true)
        assertTrue(timedOut.events.contains("interrupt"), "a timed-out recording keeps the partial take")
    }

    await runSuite("An idle failed recovery reports a deferral and doesn't interrupt anything") {
        let harness = DeviceRecoveryHarness()
        let generation = harness.notify()
        harness.reads = [.failure(FakeRewarmError())]
        await harness.attempt(generation)
        assertFalse(harness.events.contains("interrupt"), "nothing was recording")
        assertTrue(harness.events.contains("rewarmFailed(sentry: false)"), "idle settling isn't a Sentry failure")
        assertTrue(harness.events.contains("rebuild:device_change_rewarm_failed"), "the graph is still rebuilt")
    }

    await runSuite("A failed recovery doesn't rebuild a session its interruption observer cancelled") {
        let harness = DeviceRecoveryHarness()
        harness.isRecording = true
        let generation = harness.notify()
        harness.reads = [.failure(FakeRewarmError())]
        // The interruption subscriber cancels the session synchronously.
        harness.onInterrupt = { harness.state.reset() }
        await harness.attempt(generation)
        assertTrue(harness.events.contains("interrupt"), "the interruption is still published")
        assertFalse(
            harness.events.contains { $0.hasPrefix("rebuild") || $0.hasPrefix("abandon") || $0 == "prewarm" },
            "the cancellation owns the graph; recovery must recheck before rebuilding"
        )
    }

    await runSuite("A circuit-open failure keeps the current graph") {
        let harness = DeviceRecoveryHarness()
        let generation = harness.notify()
        harness.reads = [.failure(ParakeetAudioEngineWorkError.circuitOpen(operation: "snapshot", activeWorkers: 4))]
        await harness.attempt(generation)
        assertTrue(harness.events.contains("failed"), "the recovery fails closed")
        assertFalse(harness.events.contains { $0.hasPrefix("rebuild") || $0.hasPrefix("abandon") }, "no healthy graph is retired")
    }

    await runSuite("A timed-out snapshot abandons only the graph it was read from") {
        let harness = DeviceRecoveryHarness()
        let generation = harness.notify()
        harness.reads = [.failure(ParakeetAudioEngineWorkError.timedOut(operation: "snapshot", timeoutMs: 1500))]
        await harness.attempt(generation)
        assertTrue(harness.events.contains("abandon:device_change_rewarm_failed"), "a wedged queue is abandoned, not queued behind")

        let replaced = DeviceRecoveryHarness()
        let replacedGeneration = replaced.notify()
        replaced.reads = [.failure(ParakeetAudioEngineWorkError.timedOut(operation: "snapshot", timeoutMs: 1500))]
        replaced.onRead = { _ in replaced.graphGeneration += 1 }
        await replaced.attempt(replacedGeneration)
        assertFalse(replaced.events.contains { $0.hasPrefix("abandon") }, "a successor graph is never abandoned")
        assertFalse(replaced.events.contains("publish"), "the failure isn't this graph's to publish")
    }

    await runSuite("The recovery timeout releases intent, then abandons the graph it captured") {
        let harness = DeviceRecoveryHarness()
        harness.isRecording = true
        let generation = harness.notify()
        await harness.timeout(generation, wasRecording: true)
        assertEqual(
            harness.events,
            [
                "clearTimeoutTask", "releaseIntent", "publish", "timedOut(sentry: true)",
                "interrupt", "reportInterrupted", "abandon:device_change_recovery_timeout", "prewarm",
            ],
            "a terminal timeout releases restart intent rather than reanimating a failed session"
        )
        assertFalse(harness.intent, "intent is released")

        let finished = DeviceRecoveryHarness()
        let finishedGeneration = finished.notify()
        await finished.attempt(finishedGeneration)
        finished.events = []
        await finished.timeout(finishedGeneration, wasRecording: false)
        assertEqual(finished.events, [], "a recovery that already finished doesn't time out")
    }

    await runSuite("The recovery timeout doesn't rebuild a graph its publication handed to someone else") {
        for hook in ["publish", "interrupt"] {
            let harness = DeviceRecoveryHarness()
            harness.isRecording = true
            let generation = harness.notify()
            let replaceGraph = { harness.graphGeneration += 1 }
            if hook == "publish" { harness.onPublish = replaceGraph } else { harness.onInterrupt = replaceGraph }
            await harness.timeout(generation, wasRecording: true)
            assertTrue(harness.events.contains("interrupt"), "the interruption is still offered (\(hook))")
            assertFalse(
                harness.events.contains { $0.hasPrefix("abandon") || $0.hasPrefix("rebuild") || $0 == "prewarm" },
                "the timeout captured its owner before \(hook) and must not touch the successor"
            )
        }
    }
}
