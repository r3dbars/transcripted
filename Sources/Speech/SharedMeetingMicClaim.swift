// SharedMeetingMicClaim.swift
// Pure claim/staleness types for the meeting-mic sharing handshake between
// MeetingSessionController (mints claims) and ParakeetEngine (holds and
// consults them). Split out, Foundation-only, so run-tests.sh can cover the
// staleness decision without ParakeetEngine's AVAudioEngine/MainActor graph
// — mirrors the ParakeetSystemWakePolicy.swift split (pure decision next to
// the side-effecting executor that consults it).
//
// 2026-08 handshake audit: replaces ParakeetEngine.sharedMeetingMicRecording,
// a bare `var Bool` flipped from 8+ MainActor call sites with no versioning
// and no tie to the meeting side's own session identity. That flag had no
// expiry — if the meeting session that set it died without its own clear
// path running (capture-stack crash, error teardown ordering), dictation's
// device-recovery guards stayed suppressed forever. `SharedMeetingMicClaim`
// fixes that by carrying a liveness probe into the meeting session that
// minted it, so a claim can be told apart from a *stale* claim.

import Foundation

/// A claim on the meeting-owned microphone stream, minted by
/// `MeetingSessionController.startDictationFromActiveMeetingMic()` when
/// dictation begins borrowing the meeting's live mic tap.
struct SharedMeetingMicClaim {
    /// The narrowest stable identity for the meeting recording that minted
    /// this claim: `MeetingSessionController.activeRecordingIdentity`, a
    /// UUID coined once per recording start and cleared at that recording's
    /// own teardown. Carried here for equality/logging; the mint site also
    /// captures this same value into `isSessionAlive`'s closure so liveness
    /// can be checked against the CURRENT identity, not just current
    /// activity — see that property's doc for why both are required.
    let sessionIdentity: UUID

    /// Weak-captured, read-only liveness probe into the meeting session that
    /// minted this claim. Must require BOTH
    /// `MeetingSessionController.isCaptureSessionActive` (which covers the
    /// mic-engage and teardown windows in addition to steady-state
    /// recording; documented on that type as "the answer every ... gate
    /// should use") AND that the controller's *current*
    /// `activeRecordingIdentity` still equals the identity captured at mint
    /// time (`sessionIdentity` above) — an active pipeline alone is not
    /// enough, because an unexpected stop can be followed by a brand-new
    /// recording (a fresh identity) before an in-flight resume for the OLD
    /// recording gets a chance to run; without the identity check that race
    /// would read the old, orphaned claim as alive just because *some*
    /// recording happens to be active again, and let the new meeting's
    /// relay feed the old claim's borrowed-audio recorder. See
    /// `SharedMeetingMicClaimPolicy.isClaimSessionAlive` for the pure
    /// two-condition check the mint site's closure should delegate to.
    /// `false` otherwise — including when the controller deallocated, or its
    /// state machine moved on to `.idle`/`.loadingModels`/`.ready`/
    /// `.transcribing`/`.error` without releasing this claim through the
    /// normal clear path. Speech never imports Meeting types, so this
    /// closure is the entire contract — dictation asks "is the session that
    /// gave me this claim still alive?" without holding any reference to
    /// `MeetingSessionController` itself.
    let isSessionAlive: @MainActor () -> Bool
}

/// Pure, allocation-free staleness classification for a claim ParakeetEngine
/// is about to consult. Kept separate from `SharedMeetingMicClaim` itself so
/// resolving it (which requires calling `isSessionAlive()`, a MainActor
/// side effect) stays out of this Foundation-only, directly fast-testable
/// enum.
enum SharedMeetingMicClaimStatus: Equatable {
    /// No claim on file — dictation owns its own mic path.
    case absent
    /// A claim is on file and its meeting session reports itself alive.
    case current
    /// A claim is on file but its meeting session no longer reports itself
    /// alive — the crash/teardown-ordering gap this handshake exists to
    /// close. The two device-recovery guards that ask this question
    /// (`ParakeetEngine.handleSystemWake`,
    /// `ParakeetDeviceRecovery.handleAudioConfigChange`) must treat this
    /// exactly like `.absent`.
    case stale
}

/// Pure decision for the two device-recovery guards that must distinguish a
/// live meeting-owned mic from a claim orphaned by a dead meeting session.
/// Every other shared-mic call site (is dictation currently in borrowed-mic
/// bookkeeping mode at all?) asks a different, presence-only question —
/// `sharedMeetingMicClaim != nil` — because a claim on file, dead or alive,
/// still means there is no local `AVAudioEngine` to tear down; see
/// `ParakeetEngine.resolveSharedMeetingMicClaimStatus()` for where the two
/// questions diverge.
enum SharedMeetingMicClaimPolicy {
    /// True only when a live claim is on file. `.stale` and `.absent` both
    /// resolve to `false` — the whole point of the handshake is that a dead
    /// claim behaves identically to no claim at all for recovery purposes.
    static func isSharingActive(_ status: SharedMeetingMicClaimStatus) -> Bool {
        status == .current
    }

    /// The pure two-condition check `SharedMeetingMicClaim.isSessionAlive`'s
    /// mint-site closure should delegate to: a claim minted for
    /// `mintedIdentity` is alive only when the CURRENT session is both
    /// active AND is still that exact same session — `currentIdentity ==
    /// mintedIdentity`. An active pipeline is not sufficient on its own: a
    /// meeting can stop unexpectedly, schedule an async resume for
    /// dictation, and have a brand-new recording (a fresh identity) start
    /// before that resume runs. Without the identity comparison, the old
    /// claim would read as alive purely because *some* recording is active
    /// again, letting a dead claim's stale liveness check pass and the new
    /// meeting's mic relay feed the old, orphaned claim's recorder.
    /// `currentIdentity` is `nil` between recordings (`.idle`/
    /// `.loadingModels`/`.ready`) and always fails the comparison, exactly
    /// like any other mismatch.
    static func isClaimSessionAlive(
        mintedIdentity: UUID,
        currentIdentity: UUID?,
        isCaptureSessionActive: Bool
    ) -> Bool {
        isCaptureSessionActive && currentIdentity == mintedIdentity
    }
}
