import Combine
import Foundation

/// AppKit-free duration formatting for the meeting overlay and menu bar.
///
/// Extracted from `MeetingOverlayController` so the recording timer and the
/// inactivity-warning copy can be unit-tested without the AppKit panel. The
/// rendered strings are user-facing; the timer matches the island's.
enum MeetingDurationFormatter {
    /// Recording-timer label, clamped at zero. One timer format everywhere:
    /// `5:07`, `1:02:03` past an hour, the same as the island
    /// (`NotchIslandPresentation.timerText`).
    static func formatDuration(_ seconds: TimeInterval) -> String {
        let total = max(0, Int(seconds))
        let hours = total / 3600
        let minutes = (total % 3600) / 60
        let secs = total % 60
        if hours > 0 {
            return String(format: "%d:%02d:%02d", hours, minutes, secs)
        }
        return String(format: "%d:%02d", minutes, secs)
    }

    /// Inactivity-warning copy: rounds to whole minutes (minimum one) and
    /// pluralizes "minute".
    static func formatInactiveDuration(_ duration: TimeInterval) -> String {
        let minutes = max(1, Int(round(duration / 60)))
        return minutes == 1 ? "1 minute" : "\(minutes) minutes"
    }
}

extension Publisher where Output == TimeInterval {
    /// The recording duration ticks about 5 times a second. Timer labels only
    /// show whole seconds, so collapse the ticks to whole seconds and drop
    /// repeats before they trigger a layout pass.
    func wholeSecondTicks() -> AnyPublisher<Int, Failure> {
        map { Int($0) }
            .removeDuplicates()
            .eraseToAnyPublisher()
    }
}
