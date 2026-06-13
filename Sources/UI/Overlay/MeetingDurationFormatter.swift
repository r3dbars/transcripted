import Foundation

/// Foundation-pure duration formatting for the meeting overlay.
///
/// Extracted from `MeetingOverlayController` so the recording timer and the
/// inactivity-warning copy can be unit-tested without the AppKit panel. The
/// rendered strings are user-facing, so the formatting here must stay
/// byte-for-byte identical to the original inline helpers.
enum MeetingDurationFormatter {
    /// Recording-timer label, clamped at zero and rendered as `mm:ss`.
    static func formatDuration(_ seconds: TimeInterval) -> String {
        let total = max(0, Int(seconds))
        let m = total / 60
        let s = total % 60
        return String(format: "%02d:%02d", m, s)
    }

    /// Inactivity-warning copy: rounds to whole minutes (minimum one) and
    /// pluralizes "minute".
    static func formatInactiveDuration(_ duration: TimeInterval) -> String {
        let minutes = max(1, Int(round(duration / 60)))
        return minutes == 1 ? "1 minute" : "\(minutes) minutes"
    }
}
