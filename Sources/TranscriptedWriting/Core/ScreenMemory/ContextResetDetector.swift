import Foundation

/// Detects that the text around the caret changed wholesale — a different
/// conversation opened in the same window, a draft replaced — as opposed to
/// growing or shrinking at the edge through ordinary typing, deleting, or
/// accepting. Live 2026-08-23: switching threads inside one chat window kept
/// serving the previous thread's scene for up to the capture cadence,
/// because nothing told Screen Memory the content had changed.
public enum ContextResetDetector {
    /// True when `current` is neither an edge-edit of `previous` nor trivially
    /// short. Edge edits share a long common prefix; a thread switch does not.
    public static func isReset(previous: String, current: String) -> Bool {
        guard previous.count >= 12, current.count >= 12 else { return false }
        let shared = zip(previous, current).prefix { $0 == $1 }.count
        return shared * 2 < min(previous.count, current.count)
    }
}
