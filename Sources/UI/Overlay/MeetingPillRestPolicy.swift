import Foundation

/// Rest/wake policy for the meeting recording pill.
///
/// Instead of a minimize button, the pill rests down to a compact capsule
/// (status dot + timer) after a few seconds without attention. Hovering it
/// WAKES it — the full strip returns and stays until another quiet stretch
/// passes, exactly like the first rest. Hover-out never resizes anything
/// directly; only the countdown does, and it re-verifies conditions when it
/// fires. That asymmetry is what makes the interaction stable: spurious
/// exit events during resize animations can at worst start a countdown, not
/// flip the pill's size. The transcript drawer never rests: an open drawer
/// means the user is actively watching. "Keep controls visible" pins the
/// full pill for users who do not want auto-resting.
enum MeetingPillRestPolicy {
    /// Idle hover-free time before the pill rests down to the capsule.
    static let restDelaySeconds: TimeInterval = 6

    /// Whether a rest countdown should be running right now.
    static func canRest(
        isRecording: Bool,
        isTranscriptVisible: Bool,
        keepControlsVisible: Bool,
        isHovered: Bool
    ) -> Bool {
        isRecording && !isTranscriptVisible && !keepControlsVisible && !isHovered
    }

    /// Whether the pill should render as the compact capsule. Hover is not
    /// an input here on purpose: hovering wakes the pill by clearing its
    /// resting state, rather than temporarily overriding the rendering.
    static func isCondensedRendered(
        isResting: Bool,
        isRecording: Bool,
        isTranscriptVisible: Bool
    ) -> Bool {
        isResting && isRecording && !isTranscriptVisible
    }
}
