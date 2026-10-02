// ParakeetDeviceRecoverySequence.swift
// The orderings ParakeetEngine's device-change recovery and its timeout must
// keep, written against closures so the fast tests can drive them with a
// recording fake. ParakeetEngine supplies the real CoreAudio steps in
// ParakeetDeviceRecovery.swift.
//
// What this owns: releasing the latched recording intent only from the
// current generation, the AUHAL binding wait, the guard that keeps a cancelled
// or stale snapshot from committing its sample rate, the failure path and the
// timeout path, including the ownership checks around the interruption
// publication (its subscriber can cancel the session synchronously).
//
// AirPods: nothing here touches an engine or its input node. The snapshot read
// is the engine's existing leased `audioInputSnapshot`, so a Bluetooth headset
// that is the macOS default input is handled exactly as before; a reconnect
// that exposes the headset before AUHAL accepts it still waits with bounded
// sleeps instead of replacing graphs.

import Foundation

/// The graph repair both the failed recovery and the timeout end with.
@MainActor
struct ParakeetDeviceRecoveryGraphSteps {
    var currentOwner: () -> ParakeetAudioEngineQueueOwnerToken
    var ownsQueue: (_ owner: ParakeetAudioEngineQueueOwnerToken) -> Bool
    /// Rebuilds on the current audio-engine queue; false when it didn't.
    var rebuildOnQueue: (_ reason: String) async -> Bool
    /// Swaps in a fresh graph and queue when `owner` still holds them.
    var abandonBlockedGraph: (_ reason: String, _ owner: ParakeetAudioEngineQueueOwnerToken) -> Bool
    /// Resets the prewarm budget and schedules a retry.
    var scheduleFreshPrewarmRetry: () -> Void
}

/// The engine work one device-change recovery drives.
@MainActor
struct ParakeetDeviceRecoverySteps<Snapshot> {
    /// A newer route change or a cancellation owns recovery now.
    var isStale: (_ generation: UInt64) -> Bool
    /// Clears the engine's latched restart intent.
    var releaseRecordingIntent: () -> Void
    var reportAttempted: (_ artifactRetained: Bool) -> Void
    /// The one terminal workflow-recovery report.
    var reportFinished: (_ result: String, _ artifactRetained: Bool) -> Void
    /// Reads the input under one exact lease. `attempt` starts at 1.
    var readSnapshot: (_ owner: ParakeetAudioEngineQueueOwnerToken, _ attempt: Int) async throws -> Snapshot
    var readiness: (Snapshot) -> ParakeetAudioFormatReadiness
    var reportStillSettling: (Snapshot, ParakeetAudioFormatReadiness, _ attempt: Int) -> Void
    /// Waits without the wall clock in tests.
    var sleep: (_ nanoseconds: UInt64) async -> Void
    /// Commits the recovered sample rate and resets the prewarm budget.
    var commitSnapshot: (Snapshot) -> Void
    var finishRecovery: (_ success: Bool, _ generation: UInt64) -> Bool
    var cancelTimeout: () -> Void
    var publishRecoveryState: () -> Void
    var reportSucceeded: (Snapshot) -> Void
    /// Restarts the interrupted take through the ordinary start path.
    var restartRecording: () async -> ParakeetRouteRecoveryRestartOutcome
    var reportRecordingRecovered: (_ attempt: Int) -> Void
    /// Ends the take but keeps what it heard for explicit recovery.
    var interruptPreservingTimeline: () -> Void
    var reportRestartExhausted: (Snapshot) -> Void
    var hasRecoveredTimeline: () -> Bool
    var reportFailed: (Error) -> Void
    var reportRecordingInterrupted: (Error) -> Void
    var reportRewarmFailed: (Error, _ reportSentryFailure: Bool) -> Void
    var graph: ParakeetDeviceRecoveryGraphSteps
}

/// The engine work one recovery timeout drives.
@MainActor
struct ParakeetDeviceRecoveryTimeoutSteps {
    /// Fails the active recovery; false when it already finished or is stale.
    var timeoutRecovery: (_ generation: UInt64) -> Bool
    var clearTimeoutTask: () -> Void
    var releaseRecordingIntent: () -> Void
    var publishRecoveryState: () -> Void
    var reportTimedOut: (ParakeetDeviceRecoveryFailureAction) -> Void
    var interruptPreservingTimeline: () -> Void
    var reportRecordingInterrupted: () -> Void
    var graph: ParakeetDeviceRecoveryGraphSteps
}

enum ParakeetDeviceRecoverySequence {
    /// Runs one recovery for `generation`. `shouldRestartRecording` is the
    /// intent latched when the recovery was admitted; admission reads it but
    /// never clears it, so a second notification in a Bluetooth burst (which
    /// arrives with recording already stopped) inherits it. Only the current
    /// generation releases it when it ends.
    @MainActor
    static func run<Snapshot>(
        generation: UInt64,
        shouldRestartRecording: Bool,
        steps: ParakeetDeviceRecoverySteps<Snapshot>
    ) async {
        guard !steps.isStale(generation) else { return }
        var workflowRecoveryFinished = false
        func finishWorkflowRecovery(result: String, artifactRetained: Bool) {
            guard !workflowRecoveryFinished else { return }
            workflowRecoveryFinished = true
            steps.reportFinished(result, artifactRetained)
        }
        defer {
            // An older task must never clear a newer route change's intent.
            if !steps.isStale(generation) {
                steps.releaseRecordingIntent()
            }
            finishWorkflowRecovery(
                result: Task.isCancelled ? "cancelled" : "superseded",
                artifactRetained: shouldRestartRecording
            )
        }
        steps.reportAttempted(shouldRestartRecording)

        guard !Task.isCancelled else { return }
        guard !steps.isStale(generation) else { return }

        var lastSnapshotOwner: ParakeetAudioEngineQueueOwnerToken?
        do {
            var recoveryAttempt = 0
            var readySnapshot: Snapshot?
            while readySnapshot == nil {
                recoveryAttempt += 1
                let snapshotOwner = steps.graph.currentOwner()
                lastSnapshotOwner = snapshotOwner
                let snapshot: Snapshot
                do {
                    snapshot = try await steps.readSnapshot(snapshotOwner, recoveryAttempt)
                } catch {
                    if error is DictationInputDeviceBindingError {
                        // A reconnect can expose the selected device before
                        // AUHAL accepts it. The recovery timeout bounds this
                        // wait; repeatedly replacing graphs cannot fix it.
                        await steps.sleep(TranscriptedConstants.audioRecoveryDelay)
                        guard !Task.isCancelled else { return }
                        guard !steps.isStale(generation) else { return }
                        continue
                    }
                    throw error
                }
                let readiness = steps.readiness(snapshot)
                switch ParakeetDeviceRecoveryReadinessPolicy.action(for: readiness) {
                case .finishRecovery:
                    readySnapshot = snapshot
                case .keepWaiting:
                    steps.reportStillSettling(snapshot, readiness, recoveryAttempt)
                    await steps.sleep(TranscriptedConstants.audioRecoveryDelay)
                    guard !Task.isCancelled else { return }
                    guard !steps.isStale(generation) else { return }
                    continue
                }
            }
            // The snapshot read suspended; an older route's rate must not
            // overwrite the new graph, and a cancelled one commits nothing.
            guard let snapshot = readySnapshot,
                  !Task.isCancelled,
                  !steps.isStale(generation) else { return }
            steps.commitSnapshot(snapshot)

            guard !Task.isCancelled else { return }
            guard steps.finishRecovery(true, generation) else { return }
            steps.cancelTimeout()
            steps.publishRecoveryState()
            steps.reportSucceeded(snapshot)

            guard shouldRestartRecording else {
                finishWorkflowRecovery(result: "success", artifactRetained: false)
                return
            }
            switch await steps.restartRecording() {
            case .superseded:
                return
            case .restarted(let attempt):
                steps.reportRecordingRecovered(attempt)
                finishWorkflowRecovery(result: "success", artifactRetained: true)
            case .exhausted:
                steps.interruptPreservingTimeline()
                steps.reportRestartExhausted(snapshot)
                finishWorkflowRecovery(result: "failed", artifactRetained: steps.hasRecoveredTimeline())
            }
        } catch {
            guard !steps.isStale(generation) else { return }
            // A timed-out audio-engine operation means the serial engine queue
            // is wedged behind a CoreAudio call that never returned (the AirPods
            // / Bluetooth route-switch hang). Rebuilding on that same queue would
            // never run, so fail safe by abandoning the blocked graph instead.
            let graphRepair = ParakeetDeviceRecoveryFailurePolicy.graphRepair(after: error)
            if graphRepair == .abandonBlockedAudioGraph {
                guard let lastSnapshotOwner, steps.graph.ownsQueue(lastSnapshotOwner) else { return }
            }
            let failureAction = ParakeetDeviceRecoveryFailurePolicy.action(wasRecording: shouldRestartRecording)
            if steps.finishRecovery(false, generation) {
                steps.cancelTimeout()
                steps.publishRecoveryState()
            }
            steps.reportFailed(error)
            finishWorkflowRecovery(result: "failed", artifactRetained: steps.hasRecoveredTimeline())
            if failureAction.markRecordingInterrupted {
                steps.interruptPreservingTimeline()
                steps.reportRecordingInterrupted(error)
            }
            steps.reportRewarmFailed(error, failureAction.reportSentryFailure)
            // Publishing interruption can synchronously cancel the session
            // through Combine. Do not rebuild that cancellation's graph.
            guard !Task.isCancelled, !steps.isStale(generation) else { return }
            // Circuit-open means this attempt never entered the current
            // queue. The already-counted blocked workers keep their leases;
            // fail closed without retiring another healthy graph.
            if graphRepair == .keepCurrentGraph {
                return
            }
            await repairGraph(
                strategy: ParakeetDeviceRecoveryFailurePolicy.rebuildStrategy(
                    audioEngineQueueBlocked: graphRepair == .abandonBlockedAudioGraph
                ),
                reason: "device_change_rewarm_failed",
                owner: lastSnapshotOwner,
                failureAction: failureAction,
                graph: steps.graph
            )
        }
    }

    /// Ends a recovery that outlived its budget. Runs after the timeout's
    /// sleep; the caller checks cancellation and shutdown first.
    @MainActor
    static func runTimeout(
        generation: UInt64,
        wasRecording: Bool,
        steps: ParakeetDeviceRecoveryTimeoutSteps
    ) async {
        guard steps.timeoutRecovery(generation) else { return }

        // Capture ownership before publishing interruption: its subscriber
        // can synchronously cancel the old session and supersede this graph.
        let timeoutOwner = steps.graph.currentOwner()
        steps.clearTimeoutTask()
        steps.releaseRecordingIntent()
        steps.publishRecoveryState()
        let timeoutAction = ParakeetDeviceRecoveryTimeoutPolicy.action(wasRecording: wasRecording)
        let failureAction = timeoutAction.failureAction
        steps.reportTimedOut(failureAction)
        if failureAction.markRecordingInterrupted {
            steps.interruptPreservingTimeline()
            steps.reportRecordingInterrupted()
        }
        guard steps.graph.ownsQueue(timeoutOwner) else { return }
        await repairGraph(
            strategy: timeoutAction.rebuildStrategy,
            reason: "device_change_recovery_timeout",
            owner: timeoutOwner,
            failureAction: failureAction,
            graph: steps.graph
        )
    }

    @MainActor
    private static func repairGraph(
        strategy: ParakeetAudioEngineRebuildStrategy,
        reason: String,
        owner: ParakeetAudioEngineQueueOwnerToken?,
        failureAction: ParakeetDeviceRecoveryFailureAction,
        graph: ParakeetDeviceRecoveryGraphSteps
    ) async {
        switch strategy {
        case .queuedOnAudioEngineQueue:
            guard await graph.rebuildOnQueue(reason) else { return }
        case .abandonBlockedAudioGraph:
            guard let owner, graph.abandonBlockedGraph(reason, owner) else { return }
        }
        if failureAction.schedulePrewarmRetry {
            graph.scheduleFreshPrewarmRetry()
        }
    }
}
