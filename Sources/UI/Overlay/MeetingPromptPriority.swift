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

/// What the meeting overlay does when an audio-inactivity countdown reaches
/// zero.
///
/// The call-ended kind needs a reading sampled at or after its deadline before
/// it may stop: the call can rejoin in the gap between the last poll and zero.
/// So at zero the session takes that reading itself and stops right then, or
/// leaves Continue / Stop up without a countdown. Waveform silence keeps its
/// existing deadline behavior. Pure so the user-visible branch is testable without the
/// AppKit controller.
enum MeetingInactivityCountdownExpiry: Equatable {
    case stop
    /// A call-end stop needs a fresh read of the call app's audio first.
    case confirmCallEndedThenStop
    case noAutomaticStop

    static func resolve(
        isCallEnded: Bool,
        automaticStopAllowed: Bool,
        promptVisible: Bool,
        coveredSeconds: Int = 0
    ) -> Self {
        guard automaticStopAllowed else { return .noAutomaticStop }
        // Meeting ended? waits for a visible drop unless this cover stretch
        // has already used its cap. No sound never waits on visibility.
        if isCallEnded {
            let uncovered = promptVisible
                || coveredSeconds >= MeetingInactivityCountdownVisibility.coveredHoldCapSeconds
            return uncovered ? .confirmCallEndedThenStop : .noAutomaticStop
        }
        return .stop
    }
}

/// Whether the audio-inactivity / call-end countdown may tick.
///
/// Meeting ended? pauses while a dictation covers the drop and restarts
/// when it comes back, so Keep recording is actually seen. One cover
/// stretch may pause only up to `coveredHoldCapSeconds`; after that the
/// countdown proceeds (and can auto-stop) even if still covered. No sound
/// never pauses.
enum MeetingInactivityCountdownVisibility: Equatable {
    case hold
    case decrement
    case restart(seconds: Int)

    /// How long one covered Meeting ended? stretch may stay paused.
    static let coveredHoldCapSeconds = 5 * 60

    static func step(
        wasVisible: Bool,
        isVisible: Bool,
        fullSeconds: Int,
        pauseWhileHidden: Bool,
        coveredSeconds: Int = 0,
        kindChanged: Bool = false
    ) -> Self {
        if kindChanged {
            // Silence that takes over mid-countdown gets its own window,
            // not leftover Meeting ended? seconds from this same task.
            if !pauseWhileHidden {
                return .restart(seconds: max(1, fullSeconds))
            }
            return isVisible ? .restart(seconds: max(1, fullSeconds)) : .hold
        }
        let pause = pauseWhileHidden
            && coveredSeconds < coveredHoldCapSeconds
        guard pause else { return .decrement }
        guard isVisible else { return .hold }
        if !wasVisible { return .restart(seconds: max(1, fullSeconds)) }
        return .decrement
    }
}

/// One running inactivity / call-end countdown. The overlay Task and the
/// tests share this so a cover-cap tick or a call-end → silence hand-off
/// cannot drift from the loop.
struct MeetingInactivityCountdownRun: Equatable {
    var remaining: Int
    var wasVisible: Bool
    var pauseWhileHidden: Bool
    var coveredSeconds: Int = 0

    @discardableResult
    mutating func tick(
        isVisible: Bool,
        pauseWhileHidden: Bool,
        fullSeconds: Int
    ) -> MeetingInactivityCountdownVisibility {
        if isVisible {
            coveredSeconds = 0
        } else {
            coveredSeconds += 1
        }
        let kindChanged = self.pauseWhileHidden != pauseWhileHidden
        let action = MeetingInactivityCountdownVisibility.step(
            wasVisible: wasVisible,
            isVisible: isVisible,
            fullSeconds: fullSeconds,
            pauseWhileHidden: pauseWhileHidden,
            coveredSeconds: coveredSeconds,
            kindChanged: kindChanged
        )
        switch action {
        case .hold:
            break
        case .decrement:
            remaining = max(0, remaining - 1)
        case .restart(let seconds):
            remaining = seconds
        }
        wasVisible = isVisible
        self.pauseWhileHidden = pauseWhileHidden
        return action
    }
}
