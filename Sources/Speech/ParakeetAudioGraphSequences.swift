// ParakeetAudioGraphSequences.swift
// The orderings ParakeetEngine's stop, route-change recovery, route restart
// and input snapshot must keep, written against `ParakeetAudioGraph` and small
// host protocols so the fast tests can run them with a fake driver and record
// what happens in which order. ParakeetEngine supplies the real steps.
//
// AirPods: these sequences touch the graph only through ParakeetAudioGraph,
// which never creates an input node. The snapshot admission runs before the
// caller reads the input node, so the config-change ignore window is armed
// before a fresh engine can bind the macOS default input.

import Foundation

// MARK: - Stop

/// The engine state a user stop reads and settles.
@MainActor
protocol ParakeetStopRecordingHost: AnyObject {
    var hasSharedMeetingMicClaim: Bool { get }
    var isSharedMeetingMicResumeInProgress: Bool { get }
    func invalidateSharedMeetingMicTransition()
    /// Ends a dictation that borrows the meeting's mic.
    func finishSharedMeetingMicStop()
    /// The config-recovery generation in flight, if any.
    var activeConfigRecoveryGeneration: UInt64? { get }
    /// Cancels the startup watchdog and any zombie recovery, replacing a graph
    /// still blocked in that work.
    @discardableResult
    func cancelAudioWatchdog() -> Bool
    func cancelConfigRecoveryIfCurrent(generation: UInt64)
    var isRecording: Bool { get }
    func idleStopAction() -> ParakeetIdleStopAction
    func cancelPendingRecordingRecovery()
    func clearRecoveredRecordingTimeline(keepingCapacity: Bool)
    var hasPinnedDictationRecording: Bool { get }
    func stopPinnedDictationRecording() async
    /// Moves captured samples into the take and marks recording stopped.
    func finishStoppedRecording()
    func reportRecordingStopped()
}

enum ParakeetStopRecordingSequence {
    /// A stop retires the graph owner, cancels zombie recovery and its own
    /// config recovery in one MainActor turn, before its first suspension, so
    /// neither can restart the mic against the stopped session. Idle and
    /// recording stops share that cancellation.
    @MainActor
    static func run<Driver>(
        graph: ParakeetAudioGraph<Driver>,
        host: some ParakeetStopRecordingHost
    ) async {
        // A claim on file, dead or alive, still means there is no local graph
        // to tear down.
        if host.hasSharedMeetingMicClaim || host.isSharedMeetingMicResumeInProgress {
            host.invalidateSharedMeetingMicTransition()
        }
        if host.hasSharedMeetingMicClaim {
            host.finishSharedMeetingMicStop()
            return
        }

        let configRecoveryGeneration = host.activeConfigRecoveryGeneration
        graph.generation += 1
        host.cancelAudioWatchdog()
        if let configRecoveryGeneration {
            host.cancelConfigRecoveryIfCurrent(generation: configRecoveryGeneration)
        }

        guard host.isRecording else {
            // Preserved audio (say, real speech held across a wake-recovery
            // gap) wins over a merely pending zombie restart, so a stop during
            // an in-flight zombie retry drains real audio instead of dropping it.
            switch host.idleStopAction() {
            case .drainRecoveredAudio:
                host.cancelPendingRecordingRecovery()
            case .cancelPendingZombieRestart:
                // A zombie reset marks recording idle while it waits to retry,
                // with nothing preserved. A stop then cancels that restart.
                let stopGraphGeneration = graph.generation
                graph.startAdmission.cancel()
                host.clearRecoveredRecordingTimeline(keepingCapacity: true)
                await graph.releaseIdleHardware(
                    removeTap: true,
                    expectedGeneration: stopGraphGeneration
                )
            case .settleIdleGraph:
                if graph.startAdmission.isInProgress {
                    // A normal start can be blocked inside CoreAudio like a
                    // zombie restart. Cancelling its admission lets the
                    // watchdog cancellation above own its exact lease.
                    graph.startAdmission.cancel()
                } else {
                    host.clearRecoveredRecordingTimeline(keepingCapacity: true)
                }
            }
            return
        }
        if host.hasPinnedDictationRecording {
            await host.stopPinnedDictationRecording()
            return
        }
        if await graph.stopRecording(finishRecording: { host.finishStoppedRecording() }) {
            host.reportRecordingStopped()
        }
    }
}

// MARK: - Route change

/// The engine state a route change reads and settles before recovery runs.
@MainActor
protocol ParakeetConfigChangeRecoveryHost: AnyObject {
    /// Startup, a suspended stop, a borrowed meeting mic and the pinned
    /// recorder each own the graph; route recovery waits its turn.
    var admitsConfigChangeRecovery: Bool { get }
    var isRecording: Bool { get }
    /// Latches recording intent, starts a recovery generation, publishes it
    /// and arms its timeout. Returns the generation.
    func beginConfigChangeRecovery() -> UInt64
    @discardableResult
    func cancelAudioWatchdog() -> Bool
    func cancelPrewarmRetry()
    func preserveCurrentRecordingBuffersForRecovery()
    func markRecordingStoppedForRecovery()
    func cancelConfigRecoveryIfCurrent(generation: UInt64)
    func reportGraphReusedAfterConfigChange()
}

enum ParakeetConfigChangeTeardown {
    /// Tears the graph down for route recovery. The graph owner is retired and
    /// zombie recovery cancelled without suspending; a recording keeps what it
    /// heard before the tap comes off. Returns the recovery generation once the
    /// graph is ready for the debounced recovery, or nil when the change was
    /// not admitted or a newer owner took the graph, in which case only this
    /// change's own recovery generation is cancelled.
    @MainActor
    static func run<Driver>(
        graph: ParakeetAudioGraph<Driver>,
        host: some ParakeetConfigChangeRecoveryHost,
        strategy: ParakeetConfigChangeGraphStrategy,
        forceForMicrophoneSharing: Bool
    ) async -> UInt64? {
        // A route notification that lands while a user stop is suspended must
        // not take the graph or inherit the old recording bit.
        guard host.admitsConfigChangeRecovery else { return nil }
        graph.generation += 1
        let recoveryGeneration = host.beginConfigChangeRecovery()
        // The system already stopped the engine before posting the change, so
        // the tap and prewarm state are stale.
        host.cancelAudioWatchdog()
        host.cancelPrewarmRetry()

        guard let teardown = await graph.stopForRecovery(
            isRecording: host.isRecording,
            preserveRecording: { host.preserveCurrentRecordingBuffersForRecovery() },
            markRecordingStopped: { host.markRecordingStoppedForRecovery() }
        ) else {
            host.cancelConfigRecoveryIfCurrent(generation: recoveryGeneration)
            return nil
        }

        switch ParakeetConfigChangeGraphPolicy.action(
            strategy: strategy,
            releasedVoiceProcessing: teardown.releasedVoiceProcessing,
            forceForMicrophoneSharing: forceForMicrophoneSharing
        ) {
        case .reuseCurrentGraph:
            // CoreAudio already stopped this graph. Leave it in place so the
            // recovery snapshot and restart can rebind the tap without retiring
            // another engine and scheduling another late configuration echo.
            host.reportGraphReusedAfterConfigChange()
        case .rebuildGraph(let requiresFreshGraph):
            guard let rebuiltOwner = await graph.rebuild(
                reason: "configuration_change",
                requiresFreshGraph: requiresFreshGraph
            ), graph.owns(rebuiltOwner) else {
                host.cancelConfigRecoveryIfCurrent(generation: recoveryGeneration)
                return nil
            }
        }
        return recoveryGeneration
    }
}

/// How a route recovery's restart of the interrupted recording ended.
enum ParakeetRouteRecoveryRestartOutcome: Equatable {
    case restarted(attempt: Int)
    /// Every attempt the budget allowed failed, or a failure was terminal.
    case exhausted
    /// A newer route change or a cancellation took over; it owns what's next.
    case superseded
}

enum ParakeetRouteRecoveryRestart {
    /// Restarts the interrupted recording through the ordinary start path, so
    /// the segments recovery kept stay on the same recording. Retries only
    /// while the failure can still clear and the budget has time left.
    @MainActor
    static func run(
        startedAtUptime: TimeInterval,
        nowUptime: () -> TimeInterval,
        isCurrent: () -> Bool,
        startRecording: () async -> Bool,
        shouldRetry: () -> Bool,
        sleep: (UInt64) async -> Void
    ) async -> ParakeetRouteRecoveryRestartOutcome {
        var budget = ParakeetRecordingRestartBudget(startedAtUptime: startedAtUptime)
        while let attempt = budget.takeNextAttempt(nowUptime: nowUptime()) {
            guard isCurrent() else { return .superseded }
            let started = await startRecording()
            guard isCurrent() else { return .superseded }
            if started {
                return .restarted(attempt: attempt)
            }
            guard shouldRetry() else { break }
            // Wait only when another bounded attempt remains; no dead time
            // after the terminal failure.
            guard let delay = budget.delayBeforeNextAttempt(nowUptime: nowUptime()) else { break }
            await sleep(delay)
        }
        return .exhausted
    }
}

// MARK: - Recovery snapshot lease

extension ParakeetTimedAudioEngineWorkOwnership {
    /// Runs `work` under one exact lease a stop can claim. `work` gets the
    /// currency check to hand to queued graph work. Every exit finishes the
    /// lease; a result that comes back after a stop claimed it is a
    /// cancellation, never a snapshot.
    @MainActor
    func runLeased<T>(
        owner: ParakeetAudioEngineQueueOwnerToken,
        phase: ParakeetTimedAudioEngineWorkPhase,
        _ work: (_ isCurrent: @escaping () -> Bool) async throws -> T
    ) async throws -> T {
        begin(owner: owner, phase: phase)
        let value: T
        do {
            value = try await work { [self] in
                self.isActive(owner: owner, phase: phase)
            }
        } catch {
            finish(owner: owner, phase: phase)
            throw error
        }
        guard finish(owner: owner, phase: phase) else {
            throw CancellationError()
        }
        return value
    }
}

// MARK: - Input snapshot

enum ParakeetAudioInputSelectionAdmission {
    /// The MainActor half of an input snapshot before any graph read. The
    /// selection loads off the main actor; a graph that changed owners while
    /// it loaded cancels; a failed lookup fails closed (a readable format on a
    /// previously pinned graph doesn't say which mic is selected now); and the
    /// config-change ignore window is armed before the caller touches the
    /// input node. Nothing here writes the Mac-wide default input.
    @MainActor
    static func admit(
        loadSelection: () async throws -> DictationInputDeviceSelection?,
        ownsGraph: () -> Bool,
        needsIgnoreWindow: (DictationInputDeviceSelection) -> Bool,
        armIgnoreWindow: () -> Void,
        isRecoveryStale: () -> Bool
    ) async throws -> DictationInputDeviceSelection {
        let loadedSelection = try await loadSelection()
        guard ownsGraph() else { throw CancellationError() }
        try Task.checkCancellation()
        let selection = try DictationInputDeviceBindingPolicy.requireSelection(loadedSelection)
        if needsIgnoreWindow(selection) {
            armIgnoreWindow()
        }
        if isRecoveryStale() {
            throw CancellationError()
        }
        return selection
    }
}
