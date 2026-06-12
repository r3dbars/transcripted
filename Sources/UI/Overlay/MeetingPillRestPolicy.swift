import Foundation

/// Rest/bloom policy for the meeting recording pill.
///
/// Instead of a minimize button, the pill rests down to a compact capsule
/// (status dot + timer) after a few seconds without attention, and blooms
/// back to the full control strip on hover — Dynamic Island behavior. The
/// transcript drawer never rests: an open drawer means the user is actively
/// watching. "Keep controls visible" pins the full pill for users who do not
/// want auto-resting.
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

    /// Whether the pill should render as the compact capsule. A resting pill
    /// blooms (renders full) while hovered without losing its resting state,
    /// so moving the mouse away lets it settle back without a new countdown.
    static func isCondensedRendered(
        isResting: Bool,
        isRecording: Bool,
        isTranscriptVisible: Bool,
        isHovered: Bool
    ) -> Bool {
        isResting && isRecording && !isTranscriptVisible && !isHovered
    }
}
