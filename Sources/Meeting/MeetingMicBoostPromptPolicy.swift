// MeetingMicBoostPromptPolicy.swift
// Decides whether the in-meeting "Boost mic?" consent prompt (issue #500)
// may be presented after Core's mic-attenuation cue fires. Dependency-free
// so the fast-test runner compiles it standalone.

import Foundation

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
    static let declinedPromptCooldown: TimeInterval = 7 * 24 * 60 * 60

    /// Consent-only gate: present at most once per recording, and never when
    /// the user already enabled Apple voice processing in Settings.
    ///
    /// Invariant: the prompt flag is never true while nothing is recording.
    /// A late cue can land mid-stop — capture teardown awaits file handles
    /// while the published recording flags are still settling — so
    /// presentation also requires that no stop/cancel/termination teardown is
    /// in flight and that the session state machine still says recording.
    static func shouldPresent(
        isRecording: Bool,
        isFinishingRecording: Bool,
        sessionStateIsRecording: Bool,
        voiceProcessingPreferenceEnabled: Bool,
        currentOutcome: MeetingMicBoostPromptOutcome,
        now: Date = Date(),
        lastDeclinedAt: Date? = nil,
        declinedPromptCooldown: TimeInterval = Self.declinedPromptCooldown
    ) -> Bool {
        isRecording
            && !isFinishingRecording
            && sessionStateIsRecording
            && !voiceProcessingPreferenceEnabled
            && currentOutcome == .notShown
            && !isDeclineCooldownActive(
                now: now,
                lastDeclinedAt: lastDeclinedAt,
                cooldown: declinedPromptCooldown
            )
    }

    /// Stale-action gate: accepting or declining a prompt that outlived its
    /// recording must only dismiss it — never persist the global VPIO
    /// preference or record a prompt outcome for a dead recording.
    static func shouldApplyPromptAction(
        isPromptVisible: Bool,
        isRecording: Bool,
        isFinishingRecording: Bool,
        sessionStateIsRecording: Bool
    ) -> Bool {
        isPromptVisible
            && isRecording
            && !isFinishingRecording
            && sessionStateIsRecording
    }

    private static func isDeclineCooldownActive(
        now: Date,
        lastDeclinedAt: Date?,
        cooldown: TimeInterval
    ) -> Bool {
        guard let lastDeclinedAt else { return false }
        return now.timeIntervalSince(lastDeclinedAt) < cooldown
    }
}
