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
//   error           -> idle              (model selection reset while showing an error)
//   error           -> loadingModels     (prepareModels() retried from an error)
//   error           -> ready             (retry / cancel clears the error)
//   error           -> transcribing      (retry starts a new job from an error)
//
// Two blanket rules on top of the table: any state may transition to itself
// (idempotent no-op — several callers, e.g. the capture-confirmed-recording
// sink, are intentionally written to be safe no-ops when the transition
// already happened), and any state may transition to `.error` (the current
// code has no state-specific guard before surfacing a fatal error message —
// error reporting must never be blocked by the state machine).
enum MeetingSessionStateMachine {
    static func isLegalTransition(from: MeetingSessionState, to: MeetingSessionState) -> Bool {
        if from == to { return true }
        if case .error = to { return true }

        switch (from, to) {
        case (.idle, .loadingModels): return true
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
}
