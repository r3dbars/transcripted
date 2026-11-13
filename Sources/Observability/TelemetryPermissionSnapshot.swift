import Foundation

/// The permission booleans every telemetry event carries, served from memory.
///
/// Reading them live (`AVCaptureDevice`, `AXIsProcessTrusted`, and the saved
/// System Audio Recording grant in `UserDefaults`) can wait on tccd or the
/// preferences service. Telemetry is built on the main actor, so a stalled
/// read froze launch (`MeetingSessionController.wireSubscriptions` building
/// an event plan). Callers here only ever read memory; a serial utility
/// queue does the real reads.
///
/// Semantics:
/// - Before the first read lands every key is `unknown`, never `false`.
/// - A snapshot older than `maxAge` is still returned at once, and the read
///   that finds it stale starts one background refresh. Revocations made in
///   System Settings show up on the next event after that refresh.
/// - `transcriptedPermissionsDidChange` (posted after the app's own prompts
///   and checks) starts a refresh straight away. A change that arrives while
///   a read is running queues one more read, so an older answer never wins.
///
/// This is telemetry context only. Action-time permission checks
/// (`TranscriptedPermissionAccess`) stay live and authoritative.
final class TelemetryPermissionSnapshot: @unchecked Sendable {
    typealias Reader = @Sendable () -> [String: String]

    static let keys = ["mic_permission_granted", "screen_permission_granted", "accessibility_permission_granted"]
    static let unknownValue = "unknown"
    static let defaultMaxAge: TimeInterval = 5

    static let shared: TelemetryPermissionSnapshot = {
        let snapshot = TelemetryPermissionSnapshot(read: { TelemetryContext.livePermissionReads() })
        snapshot.observePermissionChanges(center: .default)
        return snapshot
    }()

    private let read: Reader
    private let now: @Sendable () -> Date
    private let maxAge: TimeInterval
    private let queue = DispatchQueue(label: "com.transcripted.telemetry.permission-snapshot", qos: .utility)
    private let lock = NSLock()
    // Guarded by `lock`.
    private var values: [String: String]?
    private var readAt: Date?
    private var refreshInFlight = false
    private var refreshRequestedDuringRead = false
    private var observer: NSObjectProtocol?

    init(read: @escaping Reader, now: @escaping @Sendable () -> Date = { Date() }, maxAge: TimeInterval = defaultMaxAge) {
        self.read = read
        self.now = now
        self.maxAge = maxAge
    }

    deinit {
        if let observer { NotificationCenter.default.removeObserver(observer) }
    }

    /// The latest snapshot, or all-unknown before the first read. Never reads
    /// a permission service on the calling thread.
    func current() -> [String: String] {
        lock.lock()
        let snapshot = values
        let isStale = readAt.map { now().timeIntervalSince($0) >= maxAge } ?? true
        let shouldStart = isStale && !refreshInFlight
        if shouldStart { refreshInFlight = true }
        lock.unlock()
        if shouldStart { queue.async { self.performRefresh() } }
        return snapshot ?? Self.unknownValues
    }

    /// Something changed a permission; read again in the background.
    func permissionsDidChange() {
        lock.lock()
        if refreshInFlight {
            refreshRequestedDuringRead = true
            lock.unlock()
            return
        }
        refreshInFlight = true
        lock.unlock()
        queue.async { self.performRefresh() }
    }

    /// Test hook: returns once every queued or re-queued read has landed.
    func waitForPendingRefreshForTesting() {
        while true {
            queue.sync {}
            lock.lock()
            let pending = refreshInFlight
            lock.unlock()
            if !pending { return }
        }
    }

    private func observePermissionChanges(center: NotificationCenter) {
        observer = center.addObserver(forName: .transcriptedPermissionsDidChange, object: nil, queue: nil) { [weak self] _ in
            self?.permissionsDidChange()
        }
    }

    private func performRefresh() {
        let fresh = Self.sanitized(read())
        lock.lock()
        values = fresh
        readAt = now()
        if refreshRequestedDuringRead {
            refreshRequestedDuringRead = false
            lock.unlock()
            queue.async { self.performRefresh() }
            return
        }
        refreshInFlight = false
        lock.unlock()
    }

    static var unknownValues: [String: String] {
        Dictionary(uniqueKeysWithValues: keys.map { ($0, unknownValue) })
    }

    /// Exactly the permission keys, each `true`, `false`, or `unknown`.
    static func sanitized(_ raw: [String: String]) -> [String: String] {
        Dictionary(uniqueKeysWithValues: keys.map { key in
            let value = raw[key]
            return (key, value == "true" || value == "false" ? value! : unknownValue)
        })
    }
}
