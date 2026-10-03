import AppKit
import CoreGraphics
import Foundation
import Synchronization

/// The true frontmost on-screen window, system-wide, by owning process and
/// window number.
struct WritingFrontWindowIdentity: Equatable, Sendable {
    let ownerProcessIdentifier: pid_t
    let windowNumber: CGWindowID
    let bundleIdentifier: String?
}

/// Writing's 1 Hz front-window poll for Screen Memory. It backs up the
/// `NSWorkspace` app-activation observer, which never hears about a window
/// change inside the same app (Cmd+`, another document window, a new tab
/// window).
///
/// Everything per tick stays on `readQueue`: a `DispatchSourceTimer` fires
/// there, reads the window, and compares it with the last read. Main hears
/// about it only on a change (see `FrontWindowChangeDetector`), so an
/// unchanged tick costs no main-thread wakeup. The bundle ID is reused while
/// (pid, window) stays the same, so an unchanged tick also skips the
/// LaunchServices read. The serial queue plus the timer's own coalescing
/// mean ticks behind a stuck LaunchServices read are skipped, not queued.
///
/// Each start makes a new poller; `stop()` cancels it for good, and a read
/// still out when it stops delivers nothing.
final class WritingFrontWindowPoller: @unchecked Sendable {
    /// Serial, and Writing's own: a stuck LaunchServices reply here can't
    /// hold up meeting detection's reads on `RunningApplicationsReader`, or
    /// tie up Swift's shared thread pool.
    static let readQueue = DispatchQueue(
        label: "com.transcripted.writing.front-window",
        qos: .utility
    )

    private let timer: DispatchSourceTimer
    private let detector = Mutex(FrontWindowChangeDetector<WritingFrontWindowIdentity>())
    /// `readQueue` only.
    private var bundleMemo = FrontWindowBundleMemo()
    /// Main only.
    private var isStopped = false
    private let onChange: @MainActor (WritingFrontWindowIdentity?) -> Void

    /// `onChange` runs on main with the new front window (nil: none found).
    /// The first read records the baseline and never calls it.
    @MainActor
    init(onChange: @escaping @MainActor (WritingFrontWindowIdentity?) -> Void) {
        self.onChange = onChange
        timer = DispatchSource.makeTimerSource(queue: Self.readQueue)
        timer.setEventHandler { [weak self] in self?.tick() }
        // Same 1 s cadence as before; the slack lets macOS coalesce wakeups.
        timer.schedule(deadline: .now(), repeating: .seconds(1), leeway: .milliseconds(500))
        timer.activate()
    }

    @MainActor
    func stop() {
        isStopped = true
        timer.cancel()
    }

    deinit {
        timer.cancel()
    }

    private func tick() {
        let identity = Self.readFrontWindowIdentity { pid, window in
            bundleMemo.bundleIdentifier(pid: pid, window: window) {
                NSRunningApplication(processIdentifier: $0)?.bundleIdentifier
            }
        }
        guard detector.withLock({ $0.record(identity) }) else { return }
        DispatchQueue.main.async { [weak self] in
            MainActor.assumeIsolated { self?.deliver() }
        }
    }

    @MainActor
    private func deliver() {
        guard !isStopped else { return }
        guard case .some(let identity) = detector.withLock({ $0.takeDelivery() }) else { return }
        onChange(identity)
    }

    /// `CGWindowListCopyWindowInfo` documents its result as front-to-back
    /// ordered, so the first normal-layer (`0`) window is frontmost.
    /// Deliberately doesn't use window names or titles: this only needs an
    /// identity to detect change, and nothing here reads or stores what the
    /// window is titled.
    static func readFrontWindowIdentity(
        bundleIdentifier: (pid_t, CGWindowID) -> String? = { pid, _ in
            NSRunningApplication(processIdentifier: pid)?.bundleIdentifier
        }
    ) -> WritingFrontWindowIdentity? {
        guard let list = CGWindowListCopyWindowInfo(
            [.optionOnScreenOnly, .excludeDesktopElements],
            kCGNullWindowID
        ) as? [[String: Any]] else { return nil }
        for info in list {
            guard let layer = info[kCGWindowLayer as String] as? Int, layer == 0 else { continue }
            guard let pid = info[kCGWindowOwnerPID as String] as? pid_t,
                  let windowNumber = info[kCGWindowNumber as String] as? CGWindowID
            else { continue }
            return WritingFrontWindowIdentity(
                ownerProcessIdentifier: pid,
                windowNumber: windowNumber,
                bundleIdentifier: bundleIdentifier(pid, windowNumber)
            )
        }
        return nil
    }
}
