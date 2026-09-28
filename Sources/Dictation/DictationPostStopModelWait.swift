import Foundation

/// The second stage of stopping a dictation: once the take is checkpointed,
/// wait for the voice model if it isn't loaded yet, instead of calling the wait
/// "Transcribing" before the model can run.
///
/// `DictationSessionController.stopDictationAndPaste` runs this with the real
/// router, overlay and clock; tests run it with fakes and a fake clock, so the
/// wait's decisions (kick a load nobody started, join one in flight, give up on
/// a failed load right away, stop at the budget) are checked without waiting
/// in real time.
///
/// Unlike the start path's wait (`DictationSession.waitForModelAndStart`), a
/// failed load is not retried here: the recording is already saved, so the
/// user gets the saved-recording message straight away.
@MainActor
enum DictationPostStopModelWait {
    enum Outcome: Equatable {
        /// The model was already loaded; nothing waited.
        case alreadyLoaded
        /// The model finished loading during the wait.
        case ready
        /// The session ended or changed during the wait. Do nothing more.
        case abandoned
        /// The load failed or the wait ran out of budget.
        case unavailable
    }

    struct Marks: Equatable {
        var waitStartedAt: CFAbsoluteTime?
        var readyAt: CFAbsoluteTime?
    }

    struct Result: Equatable {
        var outcome: Outcome
        var marks: Marks
    }

    struct Steps {
        /// The stop task wasn't cancelled, the user is still dictating, and
        /// it's still the same session.
        var isCurrent: @MainActor () -> Bool
        var isModelLoaded: @MainActor () -> Bool
        var modelState: @MainActor () -> ParakeetModelState
        /// Starts (or joins) the deduplicated model initialization.
        var requestModelInitialization: @MainActor () -> Void
        /// Waits for the next model-load progress change, or the deadline.
        var waitForProgress: @MainActor (_ deadline: TimeInterval) async -> Void
        /// Runs once when a wait begins (log it, show the post-stop loading overlay).
        var waitStarted: @MainActor () -> Void
        /// Runs on each pass while still waiting (refresh the overlay).
        var stillWaiting: @MainActor () -> Void
        /// Seconds since boot, for the wait deadline.
        var uptime: @MainActor () -> TimeInterval
        /// Wall-clock time, for stop-latency telemetry.
        var now: @MainActor () -> CFAbsoluteTime
        var budget: TimeInterval
    }

    static func run(_ steps: Steps) async -> Result {
        guard !steps.isModelLoaded() else {
            return Result(outcome: .alreadyLoaded, marks: Marks())
        }
        var marks = Marks(waitStartedAt: steps.now())
        steps.waitStarted()
        let deadline = steps.uptime() + steps.budget
        modelWait: while !steps.isModelLoaded(), steps.uptime() < deadline {
            guard steps.isCurrent() else { return Result(outcome: .abandoned, marks: marks) }
            steps.stillWaiting()
            switch steps.modelState() {
            case .failed:
                // The concurrent load already failed: say so now instead of
                // waiting out the whole budget.
                break modelWait
            case .notLoaded, .cached:
                // Nothing is loading the model; kick (or join) the deduped
                // initialization instead of waiting for another caller to.
                steps.requestModelInitialization()
                await steps.waitForProgress(deadline)
            case .downloading, .loading, .ready:
                await steps.waitForProgress(deadline)
            }
        }
        guard steps.isCurrent() else { return Result(outcome: .abandoned, marks: marks) }
        guard steps.isModelLoaded() else { return Result(outcome: .unavailable, marks: marks) }
        marks.readyAt = steps.now()
        return Result(outcome: .ready, marks: marks)
    }
}
