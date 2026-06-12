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
    static func shouldPresent(
        isRecording: Bool,
        isStopping: Bool = false,
        voiceProcessingPreferenceEnabled: Bool,
        currentOutcome: MeetingMicBoostPromptOutcome
    ) -> Bool {
        isRecording && !isStopping && !voiceProcessingPreferenceEnabled && currentOutcome == .notShown
    }

    static func shouldApplyAction(
        isPromptVisible: Bool,
        isRecording: Bool,
        isStopping: Bool
    ) -> Bool {
        isPromptVisible && isRecording && !isStopping
    }
}
