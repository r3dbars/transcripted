import Foundation

/// The two Release Health calls a session rotator makes. Production forwards
/// to `SentrySDK`; tests record the calls.
protocol SentrySessionSink: Sendable {
    func startSession()
    func endSession()
}

/// Owns the Release Health session state and makes every session call on a
/// private serial queue, never on the caller's thread.
///
/// `SentrySDK.startSession` / `endSession` write the session envelope to disk.
/// They used to run on main inside the sleep/wake observers and the rotation
/// timer, and that file write showed up as main-thread hangs around sleep and
/// wake. Callers (main-thread observers, the timer, Settings) only enqueue now.
/// The Sentry SDK's session calls are thread-safe (the hub guards them with its
/// own lock), so a background queue is fine for them.
///
/// The decision itself stays in `SentrySessionRotationPolicy`.
final class SentrySessionRotator: @unchecked Sendable {
    private let queue: DispatchQueue
    private let sink: any SentrySessionSink
    private let isCrashReportingEnabled: @Sendable () -> Bool
    private let now: @Sendable () -> Date
    private let sleepEndGrace: DispatchTimeInterval

    // Touched only on `queue`.
    private var sessionsAllowed = false
    private var sessionStartedAt: Date?

    init(
        sink: any SentrySessionSink,
        isCrashReportingEnabled: @escaping @Sendable () -> Bool,
        now: @escaping @Sendable () -> Date = { Date() },
        sleepEndGrace: DispatchTimeInterval = .milliseconds(200),
        label: String = "com.transcripted.sentry-session-rotation"
    ) {
        self.sink = sink
        self.isCrashReportingEnabled = isCrashReportingEnabled
        self.now = now
        self.sleepEndGrace = sleepEndGrace
        self.queue = DispatchQueue(label: label, qos: .utility)
    }

    /// The crash-reporting choice is settled (onboarding done, or the Settings
    /// toggle changed): allow sessions and start or end one to match it.
    func applyPreference() {
        queue.async { [self] in
            sessionsAllowed = true
            let shouldTrack = isCrashReportingEnabled()
            guard shouldTrack != (sessionStartedAt != nil) else { return }
            if shouldTrack {
                startOnQueue()
            } else {
                endOnQueue()
            }
        }
    }

    /// Sleep, wake, or the periodic age check. The SDK call happens on the
    /// rotation queue. Wake and the periodic check return at once.
    ///
    /// Sleep waits up to `sleepEndGrace` for the end to land. `endSession`
    /// stamps the end time when it runs, so an end that slips past suspension
    /// would count the whole sleep as session time. A slow write still can't
    /// hold main longer than the grace; it just finishes after wake, ahead of
    /// the wake start, because the queue is serial.
    func rotate(for trigger: SentrySessionRotationPolicy.Trigger) {
        let work = DispatchWorkItem { [self] in
            let action = SentrySessionRotationPolicy.action(
                for: trigger,
                sessionStartedAt: sessionStartedAt,
                wantsSession: sessionsAllowed && isCrashReportingEnabled(),
                now: now()
            )
            switch action {
            case .none:
                break
            case .end:
                endOnQueue()
            case .start:
                startOnQueue()
            case .restart:
                endOnQueue()
                startOnQueue()
            }
        }
        queue.async(execute: work)
        if trigger == .willSleep {
            _ = work.wait(timeout: .now() + sleepEndGrace)
        }
    }

    /// Normal app termination: ends the open session and waits for it, so the
    /// completed session is recorded before the process exits. Work queued
    /// earlier runs first. `queue.sync` would run the block on the caller's
    /// (main) thread, so this enqueues and waits instead.
    func endBeforeTermination() {
        let work = DispatchWorkItem { [self] in
            endOnQueue()
        }
        queue.async(execute: work)
        work.wait()
    }

    /// Waits until everything queued so far has run.
    func waitUntilIdle() {
        queue.sync {}
    }

    private func startOnQueue() {
        sink.startSession()
        sessionStartedAt = now()
    }

    private func endOnQueue() {
        guard sessionStartedAt != nil else { return }
        sessionStartedAt = nil
        sink.endSession()
    }
}
