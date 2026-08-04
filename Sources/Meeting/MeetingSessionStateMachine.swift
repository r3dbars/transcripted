// MeetingSessionStateMachine.swift
// Pure, dependency-free (Foundation-only) rules over `MeetingSessionState`
// (aka `MeetingSessionController.State`), extracted during the 2026-08
// meeting-state-collapse audit so the legal-transition table and the "what is
// the meeting doing right now" query properties get direct fast-test
// coverage instead of living only as ad hoc booleans scattered across
// MeetingSessionController.
//
// `MeetingSessionController.transition(to:reason:)` is the single writer of
// `state`. In DEBUG builds it logs (does not crash — the table below is a
// best-effort model of a very large, permissive hand-written state machine,
// not a hard invariant worth crashing a recording over) when a transition
// isn't recognized here. Legitimate new transitions should be added to this
// table, not worked around at the call site.
//
// Legal-transition table, derived from every `state = ...` (now
// `transition(to:)`) assignment in MeetingSessionController.swift and
// TranscriptionQueueCoordinator.swift as of this audit:
//
//   idle            -> loadingModels
//   idle            -> ready             (an import in flight is cancelled while a concurrent flow already reset state to idle)
//   idle            -> transcribing      (a recovered/imported job starts before prepareModels() ever ran)
//   loadingModels   -> ready
//   ready           -> idle              (model selection changed, no active work)
//   ready           -> loadingModels     (prepareModels() re-run, e.g. speech model swap)
//   ready           -> startingRecording (startRecording(), permissions + models confirmed)
//   ready           -> transcribing      (import / retranscribe / queued job starts)
//   startingRecording -> recording       (capture confirmed started)
//   recording       -> stoppingRecording (stopRecording / cancelRecording / prepareForTermination)
//   stoppingRecording -> transcribing    (stopRecording: mic audio present, job enqueued)
//   stoppingRecording -> ready           (cancelRecording, no background work left)
//   transcribing    -> ready             (queue drains with no failure)
//   transcribing    -> startingRecording (a new recording starts while an earlier one is still transcribing in the background)
//   error           -> idle              (model selection reset while showing an error)
//   error           -> loadingModels     (prepareModels() retried from an error)
//   error           -> ready             (retry / cancel clears the error)
//   error           -> transcribing      (retry starts a new job from an error)
//
// Two blanket rules on top of the table: any state may transition to itself
// (idempotent no-op — several callers are intentionally written to be safe
// no-ops when a transition already happened), and any state may transition
// to `.error` (the current code has no state-specific guard before
// surfacing a fatal error message — error reporting must never be blocked
// by the state machine).
//
// The blanket "any state -> error" rule is intentionally permissive at the
// pure (from, to) level: it can't by itself distinguish a capture session's
// own failure (legitimate — e.g. startRecording()'s capture-engage failure,
// or handleUnexpectedCaptureStop's "capture died underneath us") from an
// UNRELATED failure elsewhere in the app (an import rejected because a
// meeting is already recording, a completely different queued job's model
// prep failing in the background) that happens to fire while this session
// is separately mid-capture. Only the second kind is wrong to let through:
// letting an unrelated failure overwrite .startingRecording/.recording/
// .stoppingRecording with .error would silently clear every gate that reads
// `isCaptureSessionActive` (quit-confirm, dictation-block, mic-share,
// menubar, force-quit) for a capture that is still physically running.
// `mayReportUnrelatedFailureAsError` below is the callable, testable rule
// call sites for THAT class of failure must consult before calling
// `transition(to: .error(...))`.
enum MeetingSessionStateMachine {
    static func isLegalTransition(from: MeetingSessionState, to: MeetingSessionState) -> Bool {
        if from == to { return true }
        if case .error = to { return true }

        switch (from, to) {
        case (.idle, .loadingModels): return true
        case (.idle, .ready): return true
        case (.idle, .transcribing): return true
        case (.loadingModels, .ready): return true
        case (.ready, .idle): return true
        case (.ready, .loadingModels): return true
        case (.ready, .startingRecording): return true
        case (.ready, .transcribing): return true
        case (.startingRecording, .recording): return true
        case (.recording, .stoppingRecording): return true
        case (.stoppingRecording, .transcribing): return true
        case (.stoppingRecording, .ready): return true
        case (.transcribing, .ready): return true
        case (.transcribing, .startingRecording): return true
        case (.error, .idle): return true
        case (.error, .loadingModels): return true
        case (.error, .ready): return true
        case (.error, .transcribing): return true
        default: return false
        }
    }

    /// Broad "is the audio capture pipeline live for this recording" question
    /// — covers the mic-engage and teardown windows in addition to steady
    /// -state recording. This is the answer every "don't quit / don't let
    /// dictation touch the mic / there's runtime work happening" gate should
    /// use; see `MeetingSessionController.isCaptureSessionActive`.
    static func isCaptureSessionActive(_ state: MeetingSessionState) -> Bool {
        switch state {
        case .startingRecording, .recording, .stoppingRecording:
            return true
        case .idle, .loadingModels, .ready, .transcribing, .error:
            return false
        }
    }

    /// Narrow "is a recording actually in progress right now" question —
    /// steady state only, excluding the starting/stopping windows. This is
    /// what `MeetingSessionController.isRecording` (Stop/Start button labels,
    /// level meters) and mic-sharing gates should use.
    static func isSteadyStateRecording(_ state: MeetingSessionState) -> Bool {
        if case .recording = state { return true }
        return false
    }

    /// May a failure that is NOT about this session's own capture pipeline
    /// (an import rejected because a meeting is recording, a queued
    /// transcription job's model prep failing in the background) still force
    /// `state` to `.error`? No, while capture is live — see the header
    /// comment. Before the 2026-08 state collapse this was silently
    /// protected: `isCaptureSessionActive` OR'd in the old `isRecording`
    /// mirror (tied directly to the capture bridge, independent of `state`),
    /// so even a call site that carelessly stomped `state` to `.error` left
    /// the gates reading true because the mirror still reflected the real,
    /// physically-still-running capture. Now that `isRecording`/
    /// `isCaptureSessionActive` are both derived purely from `state`, that
    /// safety net is gone — call sites reporting an unrelated failure must
    /// check this instead of transitioning unconditionally.
    static func mayReportUnrelatedFailureAsError(while state: MeetingSessionState) -> Bool {
        !isCaptureSessionActive(state)
    }
}
