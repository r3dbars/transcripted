// ParakeetAudioGraphSequences.swift
// The orderings ParakeetEngine's start, stop, route-change recovery, route
// restart and input snapshot must keep, written against `ParakeetAudioGraph`
// and small host protocols so the fast tests can run them with a fake driver
// and record what happens in which order. ParakeetEngine supplies the real
// steps.
//
// AirPods: these sequences touch the graph only through ParakeetAudioGraph.
// The snapshot admission runs before the caller reads the input node, so the
// config-change ignore window is armed before a fresh engine can bind the
// macOS default input. The start's first input-node read is the driver's
// `prepareTap`, after the lease check at entry, same as before the seam.
// Native teardown (`ParakeetNativeInputGraphTeardown`) has no way to ask for
// an input node at all, so stop and cleanup never bind the default input.

import Combine
import Foundation
#if canImport(TranscriptedCore)
import TranscriptedCore
#endif

// MARK: - Start lease

/// Keeps the newest start's cancellation state, so a stop or zombie
/// cancellation can cut tap delivery at once.
@MainActor
protocol ParakeetAudioStartLeaseHolder: AnyObject {
    var audioStartCancellationState: ParakeetAudioStartCancellationState? { get set }
}

/// One start attempt's timed-work lease: the cancellation state that gates
/// tap delivery, plus the exact graph-work lease a stop can claim.
struct ParakeetAudioStartLease: Sendable {
    let owner: ParakeetAudioEngineQueueOwnerToken
    let state: ParakeetAudioStartCancellationState
    let ownership: ParakeetTimedAudioEngineWorkOwnership

    var isWorkCurrent: Bool {
        state.canRunWork && ownership.isActive(owner: owner, phase: .audioStart)
    }

    var canDeliverSamples: Bool {
        state.canDeliverSamples
    }
}

struct ParakeetAudioStartSnapshot {
    let engineWasRunning: Bool
    let stageTimings: [String: Int]
}

/// How a leased start ended when it did not throw.
enum ParakeetAudioStartOutcome {
    case started(ParakeetAudioStartSnapshot)
    /// A newer owner replaced the graph while the start ran.
    case graphChanged
    /// A stop cancelled the start after the engine came up.
    case cancelled
}

/// Call-app process presence. `refresh` re-polls running processes;
/// `isRunning` reads the result.
struct ParakeetCallAppPresence {
    let refresh: () -> Void
    let isRunning: () -> Bool
}

extension ParakeetAudioGraph {
    /// Starts a lease on `owner`. The previous start's lease, normal or
    /// recovery, is cancelled first, so normal and recovery starts share one
    /// replaceable lease and only the newest can deliver samples.
    func beginStartLease(
        owner: QueueOwner,
        holder: some ParakeetAudioStartLeaseHolder
    ) -> ParakeetAudioStartLease {
        let state = ParakeetAudioStartCancellationState()
        holder.audioStartCancellationState?.cancel()
        holder.audioStartCancellationState = state
        workOwnership.begin(owner: owner, phase: .audioStart)
        return ParakeetAudioStartLease(owner: owner, state: state, ownership: workOwnership)
    }

    /// Ends a lease that will never deliver: cancels it, finishes its
    /// graph-work lease, and forgets it unless a newer start replaced it.
    func endStartLease(
        _ lease: ParakeetAudioStartLease,
        holder: some ParakeetAudioStartLeaseHolder
    ) {
        lease.state.cancel()
        workOwnership.finish(owner: lease.owner, phase: .audioStart)
        if holder.audioStartCancellationState === lease.state {
            holder.audioStartCancellationState = nil
        }
    }

    /// Runs the pre-tap format reads under their own replaceable lease, so a
    /// stop can replace a graph blocked in a read instead of stranding the
    /// next start. `work` gets the currency check for queued graph work.
    /// Every exit ends the lease.
    func withStartSnapshotLease<T>(
        owner: QueueOwner,
        holder: some ParakeetAudioStartLeaseHolder,
        _ work: (_ isCurrent: @escaping () -> Bool) async throws -> T
    ) async throws -> T {
        let lease = beginStartLease(owner: owner, holder: holder)
        defer { endStartLease(lease, holder: holder) }
        return try await work { lease.isWorkCurrent }
    }
}

extension ParakeetAudioGraph where Driver: ParakeetAudioGraphStartDriver {
    /// Installs the dictation tap and starts the engine under one lease.
    ///
    /// Call apps are re-polled before the voice-processing choice, so a call
    /// app that just opened keeps its mic. The lease is checked at entry, on
    /// every tap buffer, and around `start`. A start that comes back to a
    /// replaced graph or a cancelled lease runs `cleanUpLateStart` and never
    /// delivers. A committed start keeps its state on `holder` (a stop
    /// cancels delivery through it) and schedules one call-app recheck, for
    /// a call app that opened while the engine was starting.
    func start(
        owner: QueueOwner,
        holder: some ParakeetAudioStartLeaseHolder,
        callApps: ParakeetCallAppPresence,
        voiceProcessingEnabled: (_ callAppRunning: Bool) -> Bool,
        wasPrewarmed: Bool,
        timeoutNanoseconds: UInt64,
        makeTapHandler: (ParakeetAudioStartLease) -> (Driver.TapBuffer) -> Void,
        cleanUpLateStart: () -> Void,
        recheckCallApps: () -> Void
    ) async throws -> ParakeetAudioStartOutcome {
        callApps.refresh()
        let enableVoiceProcessing = voiceProcessingEnabled(callApps.isRunning())
        let lease = beginStartLease(owner: owner, holder: holder)
        let onBuffer = makeTapHandler(lease)
        let driver = driver
        let snapshot: ParakeetAudioStartSnapshot
        do {
            snapshot = try await runTimed(
                operation: "start_recording",
                timeoutNanoseconds: timeoutNanoseconds,
                isWorkCurrent: { lease.isWorkCurrent },
                cleanupAfterCancellation: driver.cleanUpLateStart,
                cleanupAfterLateCompletion: driver.cleanUpLateStart
            ) { engine in
                try ParakeetAudioStartSequence.installTapAndStart(
                    driver: driver,
                    engine: engine,
                    lease: lease,
                    wasPrewarmed: wasPrewarmed,
                    voiceProcessingEnabled: enableVoiceProcessing,
                    onBuffer: onBuffer
                )
            }
        } catch {
            endStartLease(lease, holder: holder)
            throw error
        }
        guard owns(owner) else {
            endStartLease(lease, holder: holder)
            cleanUpLateStart()
            return .graphChanged
        }
        guard lease.state.commit() else {
            endStartLease(lease, holder: holder)
            cleanUpLateStart()
            return .cancelled
        }
        workOwnership.finish(owner: owner, phase: .audioStart)
        recheckCallApps()
        return .started(snapshot)
    }
}

enum ParakeetCallAppLaunchObservation {
    /// Calls `onLaunch` each time a call app starts running during dictation,
    /// so a running VPIO graph can hand the mic back. Repeats and closes are
    /// ignored.
    static func observe<Running: Publisher>(
        _ isCallAppRunning: Running,
        onLaunch: @escaping () -> Void
    ) -> AnyCancellable where Running.Output == Bool, Running.Failure == Never {
        isCallAppRunning
            .removeDuplicates()
            .sink { isRunning in
                guard isRunning else { return }
                onLaunch()
            }
    }
}

enum ParakeetAudioStartSequence {
    /// The graph-queue half of a start. Every step re-checks the lease, so a
    /// stop that lands mid-start never gets a running engine or samples.
    static func installTapAndStart<Driver: ParakeetAudioGraphStartDriver>(
        driver: Driver,
        engine: Driver.Engine,
        lease: ParakeetAudioStartLease,
        wasPrewarmed: Bool,
        voiceProcessingEnabled: Bool,
        onBuffer: @escaping (Driver.TapBuffer) -> Void
    ) throws -> ParakeetAudioStartSnapshot {
        guard lease.isWorkCurrent else { throw CancellationError() }
        let workStartedAt = CFAbsoluteTimeGetCurrent()
        var stageTimings: [String: Int] = [:]
        let tapFormat = try driver.prepareTap(
            on: engine,
            voiceProcessingEnabled: voiceProcessingEnabled,
            isCurrent: { lease.isWorkCurrent },
            stageTimings: &stageTimings
        )
        let tapInstallStartedAt = CFAbsoluteTimeGetCurrent()
        try driver.installTap(on: engine, format: tapFormat) { buffer in
            guard lease.canDeliverSamples else { return }
            onBuffer(buffer)
        }
        guard lease.isWorkCurrent else { throw CancellationError() }
        stageTimings["audio_tap_install_ms"] = elapsedMilliseconds(since: tapInstallStartedAt)

        let engineWasRunning = driver.isRunning(engine)
        if !wasPrewarmed || !engineWasRunning {
            stageTimings["audio_engine_prepare_ms"] = 0
            let engineStartStartedAt = CFAbsoluteTimeGetCurrent()
            guard lease.isWorkCurrent else { throw CancellationError() }
            try driver.start(engine)
            guard lease.isWorkCurrent else { throw CancellationError() }
            stageTimings["audio_engine_start_ms"] = elapsedMilliseconds(since: engineStartStartedAt)
        } else {
            stageTimings["audio_engine_prepare_ms"] = 0
            stageTimings["audio_engine_start_ms"] = 0
        }
        stageTimings["audio_start_work_ms"] = elapsedMilliseconds(since: workStartedAt)
        return ParakeetAudioStartSnapshot(
            engineWasRunning: engineWasRunning,
            stageTimings: stageTimings
        )
    }

    private static func elapsedMilliseconds(since start: CFAbsoluteTime) -> Int {
        max(0, Int((CFAbsoluteTimeGetCurrent() - start) * 1000))
    }
}

// MARK: - Native input-graph teardown

/// The AVAudioEngine calls dictation teardown makes. There is no way to ask
/// for an input node here on purpose: `AVAudioEngine.inputNode` creates one
/// on an untouched engine, which binds the macOS default input (and flips a
/// default AirPods input into call mode).
protocol ParakeetNativeInputGraph {
    associatedtype InputNode
    var isRunning: Bool { get }
    /// The input node the engine already has, or nil. Never creates one.
    var existingInputNode: InputNode? { get }
    func stop()
    func waitForStoppedInputCallbacks()
    func removeTap(from node: InputNode)
    /// Turns voice processing off. False when it stayed on.
    func releaseVoiceProcessing(on node: InputNode) -> Bool
    func isVoiceProcessingEnabled(on node: InputNode) -> Bool
}

enum ParakeetNativeInputGraphTeardown {
    /// Removes the input tap without tripping AVAudioEngine's
    /// `isSink || tap != nullptr` assertion: a running graph is stopped and
    /// its input callbacks drained first (`AudioInputTapTeardownPolicy`, the
    /// same order the meeting path uses), then voice processing is released
    /// on the stopped graph. False when voice processing stayed on.
    @discardableResult
    static func removeInputTap<Graph: ParakeetNativeInputGraph>(_ graph: Graph) -> Bool {
        let inputNode = graph.existingInputNode
        for step in AudioInputTapTeardownPolicy.steps(engineIsRunning: graph.isRunning) {
            switch step {
            case .stopEngine:
                graph.stop()
            case .waitForStoppedInputCallbacks:
                graph.waitForStoppedInputCallbacks()
            case .removeInputTap:
                if let inputNode {
                    graph.removeTap(from: inputNode)
                }
            }
        }
        return releaseStoppedVoiceProcessing(graph)
    }

    /// Stops the graph if it runs, then releases stopped voice processing.
    @discardableResult
    static func stop<Graph: ParakeetNativeInputGraph>(_ graph: Graph) -> Bool {
        if graph.isRunning {
            graph.stop()
        }
        return releaseStoppedVoiceProcessing(graph)
    }

    /// Voice processing can be released only on a stopped graph. An untouched
    /// graph has nothing to release and stays untouched.
    static func releaseStoppedVoiceProcessing<Graph: ParakeetNativeInputGraph>(_ graph: Graph) -> Bool {
        guard !graph.isRunning else { return false }
        guard let inputNode = graph.existingInputNode else { return true }
        return graph.releaseVoiceProcessing(on: inputNode)
    }

    /// The call-app probe: only an input node the graph already has can be
    /// running voice processing.
    static func usesVoiceProcessing<Graph: ParakeetNativeInputGraph>(_ graph: Graph) -> Bool {
        guard let inputNode = graph.existingInputNode else { return false }
        return graph.isVoiceProcessingEnabled(on: inputNode)
    }
}

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
