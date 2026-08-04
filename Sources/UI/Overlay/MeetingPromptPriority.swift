// MeetingPromptPriority.swift
// Pure precedence lattice for the meeting overlay's four warning-driven
// prompts (audio inactivity, system-audio degradation, audio route
// instability, mic boost). Extracted from MeetingOverlayController so the
// rule is encoded once instead of being re-derived by hand across four
// apply*/clear* method pairs.
//
// Deliberately Foundation-pure and independent of both
// MeetingOverlayController and MeetingSessionController: those pull in
// AppKit/TranscriptedCore-heavy dependencies that the root fast-test runner
// (run-tests.sh) does not compile. Callers translate their own richer types
// (CaptureRouteStabilizationOutcome, MeetingSessionController.State, ...)
// down to the primitives this file needs.

import Foundation

/// Which of the meeting overlay's prompt kinds is currently in play.
/// Shared between the pure resolver below and `MeetingOverlayController`
/// (which typealiases its own `PromptKind` to this).
enum MeetingWarningPromptKind: Equatable {
    case systemAudio
    case audioInactivity
    case micBoost
    case audioRoute
    // Post-call "that call wasn't recorded" awareness nudge. Not one of the
    // four warning-driven kinds below — MeetingOverlayController presents it
    // outside this resolver (it can only appear while not recording, so it
    // never competes with the warning lattice) — see
    // `MeetingPromptPresentationGate.allowsDetectedMeetingPrompt`.
    case missedCall
}

enum MeetingPromptPriority {
    /// Resolves which of the four warning-driven prompts (if any) the
    /// meeting overlay should currently show, given the latest value of each
    /// signal.
    ///
    /// Precedence: `audioInactivity` > `systemAudio` > `{audioRoute, micBoost}`.
    ///
    /// - `audioInactivity` always wins: it can auto-stop the recording, so
    ///   its countdown must stay visible over anything else.
    /// - `systemAudio` is gated by `MeetingSystemAudioPromptPolicy`, which
    ///   already folds in "never fight an active inactivity prompt" — this
    ///   branch is only reached once `inactivity` is nil, so that policy
    ///   check is passed `hasAudioInactivityWarning: false`.
    /// - `audioRoute` and `micBoost` are mutually sticky: whichever one is
    ///   already the active prompt (`current`) stays active even if the
    ///   other's condition also becomes true, so (say) a route hiccup can't
    ///   get silently swapped out from under the user by a mic-boost offer,
    ///   or vice versa. When neither is currently active, `audioRoute` wins
    ///   the tie — this matches every clear*-fallback chain in the
    ///   pre-resolver code, which always re-checked `audioRoute` before
    ///   `micBoost` once a higher-priority prompt cleared.
    static func resolve(
        inactivity: MeetingAudioInactivityWarning?,
        systemAudio: MeetingSystemAudioDegradationWarning?,
        routeActive: Bool,
        micBoostVisible: Bool,
        current: MeetingWarningPromptKind?,
        isRecording: Bool
    ) -> MeetingWarningPromptKind? {
        // All four warnings are recording-only: MeetingSessionController only
        // latches them while actively recording, and the overlay must never
        // keep showing a stale warning prompt once recording stops.
        guard isRecording else { return nil }

        if inactivity != nil {
            return .audioInactivity
        }

        if MeetingSystemAudioPromptPolicy.shouldPresentSystemAudioPrompt(
            warning: systemAudio,
            hasAudioInactivityWarning: false
        ) {
            return .systemAudio
        }

        if current == .audioRoute, routeActive {
            return .audioRoute
        }
        if current == .micBoost, micBoostVisible {
            return .micBoost
        }
        if routeActive {
            return .audioRoute
        }
        if micBoostVisible {
            return .micBoost
        }
        return nil
    }
}
