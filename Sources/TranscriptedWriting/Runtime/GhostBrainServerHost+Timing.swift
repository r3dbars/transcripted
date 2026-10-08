import Foundation

extension GhostBrainServerHost {
    /// Whole milliseconds between two instants, floored at zero — same
    /// rounding/floor behavior as `ScreenCaptureService.milliseconds`,
    /// duplicated here rather than shared because the two types have no
    /// common module to host it in without a bigger refactor than this
    /// change warrants. Internal, not private, so the rounding is directly
    /// testable.
    static func milliseconds(from start: Date, to end: Date) -> Int {
        max(0, Int((end.timeIntervalSince(start) * 1000).rounded()))
    }

    /// Monotonic counterpart, for spans timed with `systemUptime`.
    static func milliseconds(since start: TimeInterval) -> Int {
        max(0, Int(((ProcessInfo.processInfo.systemUptime - start) * 1_000).rounded()))
    }
}
