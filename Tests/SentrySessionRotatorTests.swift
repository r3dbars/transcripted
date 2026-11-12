import Foundation

/// Sleep, wake and the periodic check rotate the Release Health session in the
/// right order, and the SDK's session calls (a file write) never run on the
/// main thread, where they hung the app around sleep and wake.
func testSentrySessionRotator() {
    let start = Date(timeIntervalSinceReferenceDate: 2_000_000)
    let day: TimeInterval = 86_400

    runSuite("sleep ends the session and wake starts a new one, off the main thread") {
        let fixture = RotatorFixture(now: start)
        fixture.fromMain { rotator in
            rotator.applyPreference()
            rotator.rotate(for: .willSleep)
            rotator.rotate(for: .didWake)
        }
        fixture.rotator.waitUntilIdle()

        assertEqual(fixture.sink.calls, ["start", "end", "start"], "launch starts, sleep ends, wake starts")
        assertEqual(fixture.sink.callsOnMainThread, 0, "no session call ran on the main thread")
    }

    runSuite("a wake with no sleep notice still splits the session") {
        let fixture = RotatorFixture(now: start)
        fixture.fromMain { rotator in
            rotator.applyPreference()
            rotator.rotate(for: .didWake)
        }
        fixture.rotator.waitUntilIdle()

        assertEqual(fixture.sink.calls, ["start", "end", "start"], "the open session ends before the new one starts")
        assertEqual(fixture.sink.callsOnMainThread, 0, "no session call ran on the main thread")
    }

    runSuite("the periodic check restarts only a day-old session") {
        let fixture = RotatorFixture(now: start)
        fixture.fromMain { $0.applyPreference() }
        fixture.rotator.waitUntilIdle()

        fixture.clock.set(start.addingTimeInterval(day - 1))
        fixture.fromMain { $0.rotate(for: .periodicCheck) }
        fixture.rotator.waitUntilIdle()
        assertEqual(fixture.sink.calls, ["start"], "a session younger than a day stays open")

        fixture.clock.set(start.addingTimeInterval(day))
        fixture.fromMain { $0.rotate(for: .periodicCheck) }
        fixture.rotator.waitUntilIdle()
        assertEqual(fixture.sink.calls, ["start", "end", "start"], "a day-old session is ended, then restarted")
        assertEqual(fixture.sink.callsOnMainThread, 0, "no session call ran on the main thread")
    }

    runSuite("no session opens before the crash-reporting choice is settled") {
        let fixture = RotatorFixture(now: start)
        fixture.fromMain { rotator in
            rotator.rotate(for: .didWake)
            rotator.rotate(for: .periodicCheck)
        }
        fixture.rotator.waitUntilIdle()

        assertEqual(fixture.sink.calls, [], "wake before onboarding starts nothing")
    }

    runSuite("turning crash reporting off ends the session and wake keeps it off") {
        let fixture = RotatorFixture(now: start)
        fixture.fromMain { $0.applyPreference() }
        fixture.rotator.waitUntilIdle()

        fixture.enabled.set(false)
        fixture.fromMain { rotator in
            rotator.applyPreference()
            rotator.rotate(for: .didWake)
        }
        fixture.rotator.waitUntilIdle()

        assertEqual(fixture.sink.calls, ["start", "end"], "opting out closes the session and no new one starts")
        assertEqual(fixture.sink.callsOnMainThread, 0, "no session call ran on the main thread")
    }

    runSuite("termination ends the open session before returning, once") {
        let fixture = RotatorFixture(now: start)
        fixture.fromMain { rotator in
            rotator.applyPreference()
            rotator.endBeforeTermination()
        }
        assertEqual(fixture.sink.calls, ["start", "end"], "the session is ended by the time termination returns")

        fixture.fromMain { $0.endBeforeTermination() }
        assertEqual(fixture.sink.calls, ["start", "end"], "a second end with no open session does nothing")
        assertEqual(fixture.sink.callsOnMainThread, 0, "no session call ran on the main thread")
    }
}

private struct RotatorFixture {
    let sink = RecordingSessionSink()
    let clock: LockedBox<Date>
    let enabled = LockedBox(true)
    let rotator: SentrySessionRotator

    init(now: Date) {
        let clock = LockedBox(now)
        let enabled = self.enabled
        self.clock = clock
        rotator = SentrySessionRotator(
            sink: sink,
            isCrashReportingEnabled: { enabled.get() },
            now: { clock.get() },
            label: "test.sentry-session-rotation"
        )
    }

    /// Calls the rotator from the main thread, the way the sleep/wake
    /// observers, the rotation timer, Settings and termination do. The fast
    /// tests themselves run off main, so this hops over when needed.
    func fromMain(_ calls: (SentrySessionRotator) -> Void) {
        let rotator = rotator
        withoutActuallyEscaping(calls) { calls in
            let body = {
                assertTrue(Thread.isMainThread, "the rotator is called from the main thread")
                calls(rotator)
            }
            if Thread.isMainThread {
                body()
            } else {
                DispatchQueue.main.sync(execute: body)
            }
        }
    }
}

private final class LockedBox<Value>: @unchecked Sendable {
    private let lock = NSLock()
    private var value: Value

    init(_ value: Value) { self.value = value }

    func get() -> Value { lock.withLock { value } }
    func set(_ newValue: Value) { lock.withLock { value = newValue } }
}

private final class RecordingSessionSink: SentrySessionSink, @unchecked Sendable {
    private let lock = NSLock()
    private var recorded: [String] = []
    private var mainThreadCount = 0

    var calls: [String] { lock.withLock { recorded } }
    var callsOnMainThread: Int { lock.withLock { mainThreadCount } }

    func startSession() { record("start") }
    func endSession() { record("end") }

    private func record(_ call: String) {
        let onMain = Thread.isMainThread
        lock.withLock {
            recorded.append(call)
            if onMain { mainThreadCount += 1 }
        }
    }
}
