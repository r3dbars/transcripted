import Foundation

/// The Writing tab's two refresh timers: the 1 s live read and the 5 s stats
/// read. The Settings window stays alive when it closes, so the page owns
/// these separately from its notification observers: closing the window
/// suspends them (no wakeups for a page nobody sees), and showing it again
/// resumes them once. Both carry a small tolerance so the system can
/// coalesce their wakeups.
@MainActor
final class WritingRefreshTimers {
    static let liveTolerance: TimeInterval = 0.1
    static let statsTolerance: TimeInterval = 0.5

    let liveInterval: TimeInterval
    let statsInterval: TimeInterval
    private(set) var liveTimer: Timer?
    private(set) var statsTimer: Timer?

    nonisolated init(liveInterval: TimeInterval, statsInterval: TimeInterval) {
        self.liveInterval = liveInterval
        self.statsInterval = statsInterval
    }

    var isRunning: Bool { liveTimer != nil || statsTimer != nil }

    /// Arms both timers unless they're already running. Returns whether it
    /// armed them, so a caller can refresh once on a real resume.
    @discardableResult
    func resume(
        live: @escaping @MainActor @Sendable () -> Void,
        stats: @escaping @MainActor @Sendable () -> Void
    ) -> Bool {
        guard !isRunning else { return false }
        let liveTimer = Timer(timeInterval: liveInterval, repeats: true) { _ in
            Task { @MainActor in live() }
        }
        liveTimer.tolerance = Self.liveTolerance
        let statsTimer = Timer(timeInterval: statsInterval, repeats: true) { _ in
            Task { @MainActor in stats() }
        }
        statsTimer.tolerance = Self.statsTolerance
        RunLoop.main.add(liveTimer, forMode: .common)
        RunLoop.main.add(statsTimer, forMode: .common)
        self.liveTimer = liveTimer
        self.statsTimer = statsTimer
        return true
    }

    func suspend() {
        liveTimer?.invalidate()
        liveTimer = nil
        statsTimer?.invalidate()
        statsTimer = nil
    }
}

/// Rescrubbing an old day file cannot change the current day's preview.
/// Missing payloads remain a conservative invalidation for older producers.
enum WritingDayRefreshPolicy {
    static func shouldReload(savedURL: URL?, todayURL: URL) -> Bool {
        guard let savedURL else { return true }
        return savedURL.standardizedFileURL == todayURL.standardizedFileURL
    }
}
