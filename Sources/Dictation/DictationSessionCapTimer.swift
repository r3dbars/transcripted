import Foundation

/// The clock behind the 5-minute dictation cap: sleep until the last 30
/// seconds, then tick every second so the listening pill counts down live
/// (announcing to VoiceOver once, the first time the countdown shows), and
/// return when the cap is reached or the timer is cancelled.
///
/// `DictationSessionController.installSessionTimeout` runs this with the real
/// uptime clock and `Task.sleep`, then finalizes the take itself (pasting only
/// if the original app is still frontmost). Tests run it on a fake clock, so
/// five minutes pass instantly.
@MainActor
enum DictationSessionCapTimer {
    struct Steps {
        /// Already started: the cap counts from the moment recording began,
        /// not from when this task first runs.
        var timeout: DictationSessionTimeout
        /// Longest single sleep before the warning window opens.
        var pollIntervalNanos: UInt64
        var uptime: @MainActor () -> TimeInterval
        var sleep: @MainActor (_ nanoseconds: UInt64) async -> Void
        var isCancelled: @MainActor () -> Bool
        /// Shows or refreshes the countdown; returns whether it's on screen.
        var showCountdown: @MainActor (_ remainingSeconds: Double, _ announce: Bool) -> Bool
    }

    static func run(_ steps: Steps) async {
        let timeout = steps.timeout
        var didAnnounce = false
        while !steps.isCancelled() {
            let now = steps.uptime()
            if timeout.isExpired(at: now) { break }
            let remainingSeconds = timeout.remaining(at: now) ?? 0
            let inWarningWindow = DictationSessionCapWarningPolicy.shouldWarn(remainingSeconds: remainingSeconds)
            if inWarningWindow, steps.showCountdown(remainingSeconds, !didAnnounce) {
                didAnnounce = true
            }
            // Inside the warning window, tick every second so the pill counts
            // down live. Before it, sleep until the window opens.
            let secondsUntilNextCheck = inWarningWindow
                ? min(remainingSeconds, 1)
                : remainingSeconds - DictationSessionCapWarningPolicy.warningWindowSeconds
            let checkNanos = UInt64((secondsUntilNextCheck * 1_000_000_000).rounded(.up))
            let sleepNanos = min(checkNanos, steps.pollIntervalNanos)
            if sleepNanos == 0 { break }
            await steps.sleep(sleepNanos)
        }
    }
}
