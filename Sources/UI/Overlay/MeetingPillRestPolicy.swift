import Foundation

/// Rest/wake policy for the meeting recording pill.
///
/// Instead of a minimize button, the pill rests down to a compact capsule
/// (timer only) after a few seconds without attention. Hovering it
/// WAKES it — the full strip returns and stays until another quiet stretch
/// passes, exactly like the first rest. Hover-out never resizes anything
/// directly; only the countdown does, and it re-verifies conditions when it
/// fires. That asymmetry is what makes the interaction stable: spurious
/// exit events during resize animations can at worst start a countdown, not
/// flip the pill's size. "Keep controls visible" pins the full pill for users
/// who do not want auto-resting.
enum MeetingPillRestPolicy {
    /// Idle hover-free time before the pill rests down to the capsule.
    static let restDelaySeconds: TimeInterval = 6

    /// Whether a rest countdown should be running right now.
    static func canRest(
        isRecording: Bool,
        keepControlsVisible: Bool,
        isHovered: Bool,
        hasSystemAudioWarning: Bool
    ) -> Bool {
        // The warning latch protects diagnostics and saved-artifact health.
        // It must not turn the normal recorder into a persistent status banner.
        _ = hasSystemAudioWarning
        return isRecording
            && !keepControlsVisible
            && !isHovered
    }

    /// Whether the pill should render as the compact capsule. Hover is not
    /// an input here on purpose: hovering wakes the pill by clearing its
    /// resting state, rather than temporarily overriding the rendering.
    static func isCondensedRendered(
        isResting: Bool,
        isRecording: Bool,
        hasSystemAudioWarning: Bool
    ) -> Bool {
        _ = hasSystemAudioWarning
        return isResting && isRecording
    }
}
