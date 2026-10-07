import Foundation
import AVFoundation

/// Accumulates undo closures for side effects performed while one transcription pipeline run
/// (`transcribeMultichannelPipeline` / `transcribeMicrophoneOnlyPipeline`) progresses, so a late
/// cancellation rolls back exactly what has happened without every checkpoint re-stating a
/// growing "what to clean up if cancelled" parameter list. Each side effect registers its own
/// undo as it happens; `checkCancellation()` runs them (most-recently-registered first) only if
/// the run is actually cancelled at that point.
///
/// Created fresh per pipeline run and only ever driven by that run's single sequential `async`
/// call chain — never handed to a concurrent Task or shared across runs. `@unchecked Sendable`
/// here just satisfies the compiler for the awaited hops between the pipeline's `nonisolated`
/// code and its `@MainActor` helpers; it is not asserting safety under real concurrent access.
final class PipelineRollbackRegistry: @unchecked Sendable {
    private var undos: [() async -> Void] = []

    /// Register an undo for a side effect that just happened. Undos run in LIFO order — most
    /// recently registered first — mirroring "last thing done, first thing undone".
    func register(_ undo: @escaping () async -> Void) {
        undos.append(undo)
    }

    /// Checks for cancellation. If cancelled, rolls back every registered undo and rethrows.
    func checkCancellation() async throws {
        do {
            try Task.checkCancellation()
        } catch {
            await rollbackAll()
            throw error
        }
    }

    /// Runs every registered undo (most-recently-registered first), then clears the registry.
    /// Idempotent: undos are consumed as they run, so a second call is a no-op.
    func rollbackAll() async {
        guard !undos.isEmpty else { return }
        let pending = Array(undos.reversed())
        undos.removeAll()
        AppLogger.pipeline.info("Rolling back pipeline side effects", ["steps": "\(pending.count)"])
        for undo in pending {
            await undo()
        }
    }
}
