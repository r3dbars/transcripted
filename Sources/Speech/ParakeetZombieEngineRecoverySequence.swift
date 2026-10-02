import Foundation

/// The engine work one zombie-engine recovery drives. `ParakeetEngine` supplies
/// the real CoreAudio steps; tests supply fakes that record the order.
@MainActor
struct ParakeetZombieEngineRecoverySteps {
    /// The attempt still owns `ParakeetZombieRecoveryState` for this generation.
    var isCurrent: (_ generation: UInt64) -> Bool
    /// Moves the attempt to a telemetry stage; false when it no longer owns the state.
    var advance: (_ stage: ParakeetZombieRecoveryStage, _ generation: UInt64) -> Bool
    var captureGraphOwner: () -> ParakeetAudioGraphOwnerToken
    /// Drops buffered samples and publishes recording as idle.
    var publishIdle: () -> Void
    /// Not cancelled, still current, and the graph is still `owner`'s.
    var canContinue: (_ generation: UInt64, _ owner: ParakeetAudioGraphOwnerToken) -> Bool
    /// Replaces the stale engine through a bounded reset.
    var recreateGraph: (_ generation: UInt64, _ owner: ParakeetAudioGraphOwnerToken) async -> Bool
    /// Waits for the new route to settle; throws when cancelled.
    var settle: () async throws -> Void
    /// Marks the start as this recovery's own, then runs the one restart.
    var restartRecording: (_ generation: UInt64) async -> Bool
    var clearStartGeneration: (_ generation: UInt64) -> Void
    var reportRestartOutcome: (_ started: Bool) -> Void
    var interruptPreservingRecoveredTimeline: () -> Void
    /// Consumes the attempt and reports its one terminal result.
    var finish: (_ generation: UInt64, _ result: ParakeetZombieRecoveryResult) -> Void
}

/// Ordering for the single bounded zombie-engine retry: publish idle, check
/// ownership, replace the graph, settle, then restart once. Every exit ends the
/// attempt with exactly one terminal result.
enum ParakeetZombieEngineRecoverySequence {
    /// A second detection while an attempt is active must not replace it.
    static func admit(
        _ state: inout ParakeetZombieRecoveryState,
        failureKind: String
    ) -> UInt64? {
        guard !state.isActive else { return nil }
        return state.begin(failureKind: failureKind)
    }

    /// A recording start cancels a zombie recovery unless the start is that
    /// recovery's own restart.
    static func recordingStartKeepsRecovery(
        startGeneration: UInt64?,
        state: ParakeetZombieRecoveryState
    ) -> Bool {
        guard let startGeneration else { return false }
        return state.canContinue(generation: startGeneration)
    }

    @MainActor
    static func run(generation: UInt64, steps: ParakeetZombieEngineRecoverySteps) async {
        defer {
            steps.clearStartGeneration(generation)
            if steps.isCurrent(generation) {
                steps.finish(generation, Task.isCancelled ? .cancelled : .failed)
            }
        }

        guard steps.advance(.reset, generation) else { return }
        let recoveryGraphOwner = steps.captureGraphOwner()
        steps.publishIdle()

        // Stop/config-change cancellation takes ownership of graph cleanup. The
        // superseded zombie task must not enter recreation after this point.
        guard steps.canContinue(generation, recoveryGraphOwner) else { return }
        guard await steps.recreateGraph(generation, recoveryGraphOwner) else { return }
        guard !Task.isCancelled, steps.isCurrent(generation) else { return }

        guard steps.advance(.settle, generation) else { return }
        do {
            try await steps.settle()
        } catch {
            return
        }
        guard !Task.isCancelled, steps.isCurrent(generation) else { return }

        guard steps.advance(.restart, generation) else { return }
        let started = await steps.restartRecording(generation)
        steps.clearStartGeneration(generation)
        guard steps.isCurrent(generation) else { return }

        steps.reportRestartOutcome(started)
        if started {
            steps.finish(generation, .succeeded)
        } else {
            steps.interruptPreservingRecoveredTimeline()
            steps.finish(generation, .failed)
        }
    }
}
