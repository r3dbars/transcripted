// MeetingMicBoostPromptPolicy.swift
// Decides whether the in-meeting "Boost mic?" consent prompt (issue #500)
// may be presented after Core's mic-attenuation cue fires. Dependency-free
// so the fast-test runner compiles it standalone.

/// Per-recording prompt state. The rawValues are a persisted contract:
/// they're written into transcript frontmatter (`mic_boost_prompt`) and the
/// Home scanner reads the literal "accepted".
enum MeetingMicBoostPromptOutcome: String {
    case notShown = "not_shown"
    case shown = "shown"
    case accepted = "accepted"
    case declined = "declined"
}

enum MeetingMicBoostPromptPolicy {
    /// Consent-only gate: present at most once per recording, and never when
    /// the user already enabled Apple voice processing in Settings.
    ///
    /// Invariant: the prompt flag is never true while nothing is recording.
    /// A late cue can land mid-stop; `isRecording` here is expected to be the
    /// caller's single steady-state-recording signal (state == .recording),
    /// so it already reads false once a stop/cancel/termination teardown
    /// starts — see MeetingSessionController.isRecording. Before the 2026-08
    /// state collapse this took three separate signals (a capture-level
    /// mirror, an `isFinishingRecording` flag, and the session state check)
    /// because those could disagree with each other; now that the session
    /// controller has one source of truth, they're the same boolean.
    static func shouldPresent(
        isRecording: Bool,
        voiceProcessingPreferenceEnabled: Bool,
        currentOutcome: MeetingMicBoostPromptOutcome
    ) -> Bool {
        isRecording
            && !voiceProcessingPreferenceEnabled
            && currentOutcome == .notShown
    }

    /// Stale-action gate: accepting or declining a prompt that outlived its
    /// recording must only dismiss it — never persist the global VPIO
    /// preference or record a prompt outcome for a dead recording.
    static func shouldApplyPromptAction(
        isPromptVisible: Bool,
        isRecording: Bool
    ) -> Bool {
        isPromptVisible && isRecording
    }
}
