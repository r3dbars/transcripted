import Foundation

/// The first stage of stopping a dictation: stop the mic, play the stop click,
/// then save the take to a private WAV checkpoint before anything waits on the
/// voice model.
///
/// `DictationSessionController.stopDictationAndPaste` runs this with the real
/// router, sound player and recovery store; tests run it with fakes, so the
/// order and the session fences are checked through behavior instead of by
/// reading the controller's source.
///
/// The stop click plays right after the mic stops. From then on, `isCurrent`
/// (the stop task wasn't cancelled, the user is still dictating, and it's the
/// same session) is checked after the snapshot and after the checkpoint write.
/// A stop that loses its session returns `.abandoned` and has no further
/// effect, except that a checkpoint written for it is discarded unless another
/// path has claimed it.
@MainActor
enum DictationStopCheckpoint {
    enum Outcome<Snapshot, Recovery> {
        /// The session ended or changed during the stop. Do nothing more.
        case abandoned
        /// The take is saved. Transcribe `snapshot`; keep `recovery` until the
        /// text is delivered.
        case checkpointed(snapshot: Snapshot, recovery: Recovery)
        /// No snapshot, and no audio left in memory that inference could lose.
        /// Carry on without a prepared recording.
        case noSnapshot
        /// No snapshot, but native audio is still in memory. Transcribing would
        /// consume the last copy with no durable checkpoint, so stop here.
        case checkpointUnavailable
        /// Writing the checkpoint failed.
        case checkpointFailed(Error)
    }

    /// When each step happened, for stop-latency telemetry.
    struct Marks: Equatable {
        var micStoppedAt: CFAbsoluteTime?
        var snapshotStartedAt: CFAbsoluteTime?
        var snapshotFinishedAt: CFAbsoluteTime?
        var checkpointStartedAt: CFAbsoluteTime?
        var checkpointFinishedAt: CFAbsoluteTime?
    }

    struct Result<Snapshot, Recovery> {
        var outcome: Outcome<Snapshot, Recovery>
        var marks: Marks
    }

    struct Steps<Snapshot, Recovery: Sendable> {
        /// The stop task wasn't cancelled, the user is still dictating, and
        /// it's still the same session.
        var isCurrent: @MainActor () -> Bool
        var stopMicrophone: @MainActor () async -> Void
        var playStopCue: @MainActor () -> Void
        var snapshot: @MainActor () async -> Snapshot?
        /// The work that writes the checkpoint for a snapshot. It runs off the
        /// main actor.
        var checkpointWork: @MainActor (Snapshot) -> @Sendable () throws -> Recovery
        /// The work that deletes a checkpoint written for a session that is
        /// gone. It runs off the main actor.
        var discardWork: @MainActor (Recovery) -> @Sendable () -> Void
        /// True when an abandoned session's checkpoint belongs to another path
        /// (for example Quit preserving it) and must be kept.
        var keepAbandonedCheckpoint: @MainActor () -> Bool
        var hasRecoverableRecording: @MainActor () -> Bool
        var now: @MainActor () -> CFAbsoluteTime
    }

    static func run<Snapshot, Recovery: Sendable>(
        _ steps: Steps<Snapshot, Recovery>
    ) async -> Result<Snapshot, Recovery> {
        var marks = Marks()
        func finish(_ outcome: Outcome<Snapshot, Recovery>) -> Result<Snapshot, Recovery> {
            Result(outcome: outcome, marks: marks)
        }

        await steps.stopMicrophone()
        marks.micStoppedAt = steps.now()
        // The only end-of-take click. It plays once the mic is stopped, so on
        // speakers it can't land in the take, and before transcription and
        // paste, so it means "got it", not "pasted".
        steps.playStopCue()
        guard steps.isCurrent() else { return finish(.abandoned) }

        marks.snapshotStartedAt = steps.now()
        guard let snapshot = await steps.snapshot() else {
            marks.snapshotFinishedAt = steps.now()
            guard steps.isCurrent() else { return finish(.abandoned) }
            // A converter/owner race may fail the WAV snapshot while native
            // audio survives. Inference would consume that last RAM copy
            // without a durable checkpoint.
            if DictationTerminationAdmissionPolicy.mustStopBeforeInference(
                snapshotAvailable: false,
                hasRecoverableRecording: steps.hasRecoverableRecording()
            ) {
                return finish(.checkpointUnavailable)
            }
            return finish(.noSnapshot)
        }
        marks.snapshotFinishedAt = steps.now()
        guard steps.isCurrent() else { return finish(.abandoned) }

        marks.checkpointStartedAt = steps.now()
        let work = steps.checkpointWork(snapshot)
        let recovery: Recovery
        do {
            recovery = try await Task.detached(priority: .userInitiated) { try work() }.value
        } catch {
            marks.checkpointFinishedAt = steps.now()
            guard steps.isCurrent() else { return finish(.abandoned) }
            return finish(.checkpointFailed(error))
        }
        marks.checkpointFinishedAt = steps.now()
        guard steps.isCurrent() else {
            if !steps.keepAbandonedCheckpoint() {
                let discard = steps.discardWork(recovery)
                await Task.detached(priority: .utility) { discard() }.value
            }
            return finish(.abandoned)
        }
        return finish(.checkpointed(snapshot: snapshot, recovery: recovery))
    }
}
