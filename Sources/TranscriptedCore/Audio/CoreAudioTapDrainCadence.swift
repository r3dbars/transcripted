import Foundation

/// How often the system tap's consumer drains its ring.
///
/// The IOProc queues a 512-frame buffer about every 10.7 ms at 48 kHz. A
/// 10 ms drain tick for a whole meeting costs ~100 wakeups and ~300 context
/// switches a second. So the drain runs fast only until the first buffer
/// after each start or rebuild (a reconnect's pad and the first-buffer checks
/// stay prompt), then settles to a 50 ms tick that hands the writer the same
/// buffers, in the same order, about five at a time.
///
/// Queue-confined to the capture's consumer queue, like the timer it drives.
struct CoreAudioTapDrainCadence {
    struct Tick: Equatable {
        let intervalMilliseconds: Int
        let leewayMilliseconds: Int
        var interval: DispatchTimeInterval { .milliseconds(intervalMilliseconds) }
        var leeway: DispatchTimeInterval { .milliseconds(leewayMilliseconds) }
    }

    /// Until the first buffer after a start or rebuild.
    static let fast = Tick(intervalMilliseconds: 10, leewayMilliseconds: 2)
    /// Once buffers flow. The ring holds ~27 of these ticks at 48 kHz/512
    /// frames and ~6 at 192 kHz.
    static let steady = Tick(intervalMilliseconds: 50, leewayMilliseconds: 10)
    /// Backstop for a late or missing format listener (deep review M11).
    /// Under the steady tick minus its leeway, so every steady drain polls.
    static let formatPollSeconds: TimeInterval = 0.03

    private(set) var isFast = false

    /// Arms a freshly made drain timer at the fast cadence.
    mutating func start(_ timer: DispatchSourceTimer) {
        timer.schedule(deadline: .now(), repeating: Self.fast.interval, leeway: Self.fast.leeway)
        isFast = true
    }

    /// Moves a fast timer to the steady cadence once a buffer came through.
    /// Returns true when it switched.
    @discardableResult
    mutating func settle(_ timer: DispatchSourceTimer?, hasDeliveredBuffer: Bool) -> Bool {
        guard isFast, hasDeliveredBuffer, let timer else { return false }
        timer.schedule(
            deadline: .now() + Self.steady.interval,
            repeating: Self.steady.interval,
            leeway: Self.steady.leeway
        )
        isFast = false
        return true
    }
}
