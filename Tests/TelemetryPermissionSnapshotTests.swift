import Foundation

/// A fake permission service that can be held shut. It records whether the
/// caller's own thread ever ran it, so a reader that would block the caller
/// fails the test instead of hanging it.
private final class GatedPermissionReader: @unchecked Sendable {
    private let lock = NSLock()
    private let gate = DispatchSemaphore(value: 0)
    private var values: [String: String]
    private var gated = true
    private var callerThreadReads = 0
    private var backgroundReads = 0
    private let callerThread: Thread

    init(values: [String: String], callerThread: Thread) {
        self.values = values
        self.callerThread = callerThread
    }

    func read() -> [String: String] {
        if Thread.current == callerThread {
            // Never block the caller: count it and return what a synchronous
            // read would have returned, so the assertion fails cleanly.
            lock.lock(); callerThreadReads += 1; let current = values; lock.unlock()
            return current
        }
        // Answer with the values as they were when the read began, like a
        // real service that took its reading and then stalled.
        lock.lock(); let mustWait = gated; let current = values; lock.unlock()
        if mustWait { gate.wait() }
        lock.lock(); backgroundReads += 1; lock.unlock()
        return current
    }

    func open() {
        lock.lock(); let wasGated = gated; gated = false; lock.unlock()
        if wasGated { gate.signal() }
    }

    func set(_ key: String, _ value: String) {
        lock.lock(); values[key] = value; lock.unlock()
    }

    var readsOnCaller: Int { lock.lock(); defer { lock.unlock() }; return callerThreadReads }
    var readsInBackground: Int { lock.lock(); defer { lock.unlock() }; return backgroundReads }
}

private final class ManualClock: @unchecked Sendable {
    private let lock = NSLock()
    private var current = Date(timeIntervalSince1970: 1_000)
    func now() -> Date { lock.lock(); defer { lock.unlock() }; return current }
    func advance(_ seconds: TimeInterval) { lock.lock(); current += seconds; lock.unlock() }
}

func testTelemetryPermissionSnapshot() {
    let granted = [
        "mic_permission_granted": "true",
        "screen_permission_granted": "true",
        "accessibility_permission_granted": "false",
    ]

    runSuite("Telemetry never waits on a blocked permission service on the calling thread") {
        let reader = GatedPermissionReader(values: granted, callerThread: Thread.current)
        let clock = ManualClock()
        let snapshot = TelemetryPermissionSnapshot(read: { reader.read() }, now: { clock.now() }, maxAge: 5)

        // The permission service is stuck. Building an event plan on the main
        // actor still has to finish, and must say the permissions are unknown
        // rather than claiming they were denied.
        let first = snapshot.current()
        let plan = ObservabilityEventCapturePlan.make(
            level: .error, engine: "meeting", event: "meeting_recording_start_failed",
            message: "start failed", context: ["failure_kind": "mic_unavailable"], engineState: nil,
            infoDictionary: nil, timestamp: "2026-11-13T00:00:00Z", appVersion: "1.0", osVersion: "26",
            permissions: snapshot.current()
        )
        let tracked = TelemetryContext.enrich(event: "dictation_started", properties: [:], environment: snapshot.current())
        assertEqual(reader.readsOnCaller, 0, "the calling thread never reads the permission service")
        for key in TelemetryPermissionSnapshot.keys {
            assertEqual(first[key], "unknown", "\(key) is unknown before the first read lands")
            assertEqual(plan.mergedContext[key], "unknown", "the event plan carries unknown \(key), not false")
            assertEqual(tracked[key], "unknown", "the analytics event carries unknown \(key), not false")
        }
        let sanitized = AnalyticsPayloadSanitizer.sanitizeProperties(tracked, allowedKeys: TelemetryContext.keys)
        assertEqual(sanitized["mic_permission_granted"], "unknown", "unknown survives the analytics sanitizer")

        // Once the slow read answers, later events carry its real values.
        reader.open()
        snapshot.waitForPendingRefreshForTesting()
        let delayed = snapshot.current()
        assertEqual(delayed, granted, "delayed permission values reach later events exactly")
        let later = TelemetryContext.enrich(event: "dictation_started", properties: [:], environment: delayed)
        assertEqual(later["screen_permission_granted"], "true", "a granted value is reported as granted")
        assertEqual(later["accessibility_permission_granted"], "false", "a denied value is reported as denied")
        assertEqual(reader.readsOnCaller, 0, "still no read on the calling thread")
    }

    runSuite("A permission change refreshes the telemetry snapshot without waiting for it to age") {
        let reader = GatedPermissionReader(values: granted, callerThread: Thread.current)
        reader.open()
        let clock = ManualClock()
        let snapshot = TelemetryPermissionSnapshot(read: { reader.read() }, now: { clock.now() }, maxAge: 5)
        _ = snapshot.current()
        snapshot.waitForPendingRefreshForTesting()
        assertEqual(snapshot.current()["mic_permission_granted"], "true", "starts granted")

        reader.set("mic_permission_granted", "false")
        snapshot.permissionsDidChange()
        snapshot.waitForPendingRefreshForTesting()
        assertEqual(snapshot.current()["mic_permission_granted"], "false", "revocation is reported after the change signal")
        assertEqual(clock.now(), Date(timeIntervalSince1970: 1_000), "no virtual time had to pass")
        assertEqual(reader.readsOnCaller, 0, "the change signal never reads on the caller")
    }

    runSuite("A revocation made outside the app shows up once the snapshot ages") {
        let reader = GatedPermissionReader(values: granted, callerThread: Thread.current)
        reader.open()
        let clock = ManualClock()
        let snapshot = TelemetryPermissionSnapshot(read: { reader.read() }, now: { clock.now() }, maxAge: 5)
        _ = snapshot.current()
        snapshot.waitForPendingRefreshForTesting()
        let readsAfterFirst = reader.readsInBackground

        reader.set("screen_permission_granted", "false")
        clock.advance(1)
        assertEqual(snapshot.current()["screen_permission_granted"], "true", "a fresh snapshot is reused")
        snapshot.waitForPendingRefreshForTesting()
        assertEqual(reader.readsInBackground, readsAfterFirst, "a fresh snapshot does not re-read")

        clock.advance(5)
        // The stale read returns the last known values at once and starts a
        // background refresh; the next event sees the revocation.
        assertEqual(snapshot.current()["screen_permission_granted"], "true", "a stale read still answers at once")
        snapshot.waitForPendingRefreshForTesting()
        assertEqual(snapshot.current()["screen_permission_granted"], "false", "the revocation arrives after the refresh")
        assertEqual(reader.readsOnCaller, 0, "aging never reads on the caller")
    }

    runSuite("A change during a slow read is not lost to that read's older answer") {
        let reader = GatedPermissionReader(values: granted, callerThread: Thread.current)
        let clock = ManualClock()
        let snapshot = TelemetryPermissionSnapshot(read: { reader.read() }, now: { clock.now() }, maxAge: 5)
        _ = snapshot.current() // first read starts and blocks

        reader.set("mic_permission_granted", "false")
        snapshot.permissionsDidChange()
        reader.open()
        snapshot.waitForPendingRefreshForTesting()
        assertEqual(snapshot.current()["mic_permission_granted"], "false", "the change made mid-read wins")
    }

    runSuite("Only true or false from the permission service reach telemetry") {
        let reader = GatedPermissionReader(values: [
            "mic_permission_granted": "Private device label",
            "screen_permission_granted": "true",
            "unexpected_key": "true",
        ], callerThread: Thread.current)
        reader.open()
        let snapshot = TelemetryPermissionSnapshot(read: { reader.read() }, now: { Date(timeIntervalSince1970: 0) }, maxAge: 5)
        _ = snapshot.current()
        snapshot.waitForPendingRefreshForTesting()
        let values = snapshot.current()
        assertEqual(values["mic_permission_granted"], "unknown", "a non-boolean answer is unknown")
        assertEqual(values["screen_permission_granted"], "true", "a boolean answer passes")
        assertEqual(values["accessibility_permission_granted"], "unknown", "a missing answer is unknown")
        assertNil(values["unexpected_key"], "keys outside the permission set are dropped")
        let enriched = TelemetryContext.enrich(event: "dictation_started", properties: ["mic_permission_granted": "maybe"], environment: [:])
        assertEqual(enriched["mic_permission_granted"], "false", "a caller's non-boolean value still reads as false")
    }
}
