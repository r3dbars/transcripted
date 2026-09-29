import Foundation

/// Time source for orphaned-recording recovery: the single-flight owner's
/// monotonic deadline, the waits between scans, and the wall-clock "now" that
/// audio modification dates are judged against.
///
/// Production reads the real clocks. Tests install a virtual clock whose
/// sleeps only move its own time, so how many scans fit in the owner's budget
/// never depends on how busy the Mac is.
struct OrphanedRecordingRecoveryClock: Sendable {
    var now: @Sendable () -> ContinuousClock.Instant
    /// Read inside the off-main scan, right before modification dates are.
    var date: @Sendable () -> Date
    var sleep: @Sendable (Duration) async throws -> Void

    static let live = OrphanedRecordingRecoveryClock(
        now: { ContinuousClock.now },
        date: { Date() },
        sleep: { try await Task.sleep(for: $0) }
    )
}
