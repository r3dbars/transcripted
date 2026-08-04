// MeetingSessionState.swift
// The meeting session's high-level state, extracted to its own
// dependency-free (Foundation-only) file so it — and the pure
// `MeetingSessionStateMachine` built on top of it — can be covered by the
// fast-test runner without pulling in `MeetingSessionController`'s
// TranscriptedCore/Combine/ObservableObject dependencies.
//
// `MeetingSessionController.State` is a typealias onto this type (see
// MeetingSessionController.swift), so every existing
// `MeetingSessionController.State` reference keeps compiling unchanged.
//
// 2026-08 state-collapse audit: `.startingRecording` and `.stoppingRecording`
// were added so the controller has one source of truth for "what is the
// meeting doing right now" instead of layering separate `isStartingRecording`
// / `isFinishingRecording` booleans and a second `isRecording` mirror on top
// of this enum. Case names are additive and stable — this state is logged by
// name (`DiagnosticsTrail`) and feeds `MeetingPromptSessionPromptState`, so
// existing case names must never be renamed or reordered away.
enum MeetingSessionState: Equatable {
    case idle                // Models not loaded, no recording
    case loadingModels       // ensureModelsReady() in flight
    case ready               // Models loaded, ready to record
    case startingRecording   // capture.startRecording() in flight (mic engaging)
    case recording           // Capture in progress (steady state)
    case stoppingRecording   // stop/cancel/termination capture teardown in flight
    case transcribing        // Background transcription or speaker naming running
    case error(String)       // Fatal error — see message
}
