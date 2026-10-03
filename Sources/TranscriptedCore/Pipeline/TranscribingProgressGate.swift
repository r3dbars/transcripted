import Foundation

/// Thins out the pipeline's per-segment progress before it reaches the main
/// actor, without changing anything a person can read.
///
/// A long meeting reports progress once per speech segment, thousands of times,
/// and each report used to be its own main-actor task that republished
/// `displayStatus`. The gate forwards a report only when it moves into a new
/// 0.1% step of pipeline progress (under a pixel on the
/// drop-down's ~424 pt bar, so it still creeps the same) or changes the whole percent the
/// menu bar shows (`DisplayStatus.progress`, rounded down). Stage marks like
/// 0.10 and 0.30 sit on step edges, so they always go through exactly.
final class TranscribingProgressGate: @unchecked Sendable {
    struct Key: Equatable {
        /// 0.1% step of pipeline progress.
        let step: Int
        /// Whole percent of the mapped display progress, as the menu bar shows it.
        let shownPercent: Int
    }

    private let lock = NSLock()
    private var lastDelivered: Key?

    static func key(for progress: Double) -> Key {
        Key(
            step: Int((progress * 1000).rounded(.down)),
            shownPercent: Int((DisplayStatus.transcribing(progress: progress).progress * 100).rounded(.down))
        )
    }

    /// Whether `progress` differs enough from the last forwarded value to show.
    func shouldDeliver(_ progress: Double) -> Bool {
        guard progress.isFinite else { return true }
        let key = Self.key(for: progress)
        lock.lock()
        defer { lock.unlock() }
        guard key != lastDelivered else { return false }
        lastDelivered = key
        return true
    }

    /// An `onProgress` callback that hands gated values to `deliver` on the main
    /// actor, one task per forwarded value, in order.
    static func onProgress(
        _ deliver: @escaping @MainActor @Sendable (Double) -> Void
    ) -> (Double) -> Void {
        let gate = TranscribingProgressGate()
        return { progress in
            guard gate.shouldDeliver(progress) else { return }
            Task { @MainActor in deliver(progress) }
        }
    }
}
