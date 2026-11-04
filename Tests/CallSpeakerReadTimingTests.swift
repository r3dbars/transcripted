import Foundation

private actor TimingSignal {
    private var ready = false
    private var waiters: [CheckedContinuation<Void, Never>] = []
    func wait() async {
        if ready { return }
        await withCheckedContinuation { waiters.append($0) }
    }
    func signal() {
        ready = true
        let pending = waiters
        waiters = []
        pending.forEach { $0.resume() }
    }
}

private final class TimingClock: @unchecked Sendable {
    let sleeping = TimingSignal()
    let releaseSleep = TimingSignal()
    private let lock = NSLock()
    private let origin = ContinuousClock.now
    private var seconds: Double = 0
    private var sleeps = 0
    private var durations: [Double] = []
    private var host: UInt64 = 100_000

    func setHost(_ value: UInt64) { lock.withLock { host = value } }
    func advanceScheduler(by seconds: Double) { lock.withLock { self.seconds += seconds } }
    var sleepDurations: [Double] { lock.withLock { durations } }
    var hostClock: CallSpeakerHostClock {
        .init(now: { self.lock.withLock { self.host } }, ticksPerSecond: 1_000)
    }
    var pollClock: CallSpeakerPollClock {
        .init(now: { self.origin.advanced(by: .seconds(self.lock.withLock { self.seconds })) }, sleep: { duration in
            let count = self.lock.withLock {
                self.seconds += duration / .seconds(1)
                self.sleeps += 1
                self.durations.append(duration / .seconds(1))
                return self.sleeps
            }
            if count == 5 {
                await self.sleeping.signal()
                await self.releaseSleep.wait()
            }
            try Task.checkCancellation()
        })
    }
}

private func timedRead(_ timing: CallSpeakerReadTiming?) -> CallSpeakerReadResult {
    .init(supportedAppRunning: true, windows: [
        .init(match: .init(app: .zoom, meetingKey: "zoom"), tree: .init(children: [
            .init(roleDescription: "video render", description: "Test Participant, active speaker")
        ]), truncated: false)
    ], completeness: .complete, timing: timing)
}

private actor TimingReader: CallSpeakerWindowReading {
    let clock: TimingClock
    let consumerHost: UInt64
    let missingTiming: Bool
    private var reads: UInt64 = 0
    init(clock: TimingClock, consumerHost: UInt64, missingTiming: Bool = false) {
        self.clock = clock
        self.consumerHost = consumerHost
        self.missingTiming = missingTiming
    }
    func read(session: UUID) async -> CallSpeakerReadResult {
        let host = 108_000 + reads * 1_000
        reads += 1
        let result = timedRead(missingTiming ? nil : .init(startHostTime: host, endHostTime: host + 200))
        // Time spent after the actual scan, before its consumer can fold it.
        clock.setHost(consumerHost + reads * 10_000)
        clock.advanceScheduler(by: consumerHost > 500_000 ? 0.9 : 0.1)
        return result
    }
}

@MainActor
func testCallSpeakerReadTiming() async {
    await runSuite("CallSpeakerReadTiming: queued AX work excludes inventory and queue wait") {
        let clock = TimingClock()
        clock.setHost(1_000)
        let inventoryFinished = TimingSignal()
        let queue = DispatchQueue(label: "owned.test.ax-timing")
        let unblock = DispatchSemaphore(value: 0)
        queue.async {
            unblock.wait()
            clock.setHost(108_000)
        }
        let reader = CallSpeakerAXTreeReader(hostClock: clock.hostClock, readOperations: .init(
            isTrusted: { true },
            applications: {
                clock.setHost(50_000)
                await inventoryFinished.signal()
                return [.init(pid: 1, bundleID: "us.zoom.xos", host: .zoom)]
            },
            scan: { _, _ in
                clock.setHost(108_200)
                return timedRead(nil)
            }
        ), queue: queue)
        let task = Task { await reader.read(session: UUID()) }
        await inventoryFinished.wait()
        unblock.signal()
        let result = await task.value
        clock.setHost(999_000)
        assertEqual(result.timing, .init(startHostTime: 108_000, endHostTime: 108_200), "only serialized scan time is stamped")
        assertEqual(result.timing?.midpoint, 108_100, "later consumer time cannot move the observation")
        assertEqual(result.completeness, .complete, "timing does not replace scan completeness")
    }

    await runSuite("CallSpeakerReadTiming: delayed consumers change cadence but never observed speaker time") {
        @MainActor func record(consumerHost: UInt64) async -> (CallSpeakerObservedActivity?, [Double]) {
            let clock = TimingClock()
            let recorder = CallSpeakerActivityRecorder(environment: .init(
                isEnabled: { true }, isAccessibilityTrusted: { true },
                reader: TimingReader(clock: clock, consumerHost: consumerHost),
                clock: clock.pollClock, hostClock: clock.hostClock
            ))
            recorder.start(recordingStartedAt: Date(timeIntervalSince1970: 100))
            await clock.sleeping.wait()
            let result = recorder.stop()
            await clock.releaseSleep.signal()
            return (result, clock.sleepDurations)
        }
        let prompt = await record(consumerHost: 120_000)
        let delayed = await record(consumerHost: 900_000)
        assertEqual(prompt.0?.relativeActivity, delayed.0?.relativeActivity, "receipt delay cannot shift or stretch AX spans")
        assertTrue(prompt.1 != delayed.1, "the real scheduler compensated for different virtual delivery delays")
        assertEqual(delayed.0?.relativeActivity.intervals.first?.start, 8.1, "actual scan midpoint follows the host origin by8.1 seconds")
        assertEqual(delayed.0?.relativeActivity.intervals.first?.end, 12.1, "five measured polls close at the fifth midpoint")
    }

    await runSuite("CallSpeakerReadTiming: missing and reversed source stamps never become naming evidence") {
        let clock = TimingClock()
        let recorder = CallSpeakerActivityRecorder(environment: .init(
            isEnabled: { true }, isAccessibilityTrusted: { true },
            reader: TimingReader(clock: clock, consumerHost: 900_000, missingTiming: true),
            clock: clock.pollClock, hostClock: clock.hostClock
        ))
        recorder.start(recordingStartedAt: Date(timeIntervalSince1970: 100))
        await clock.sleeping.wait()
        assertTrue(recorder.stop() == nil, "the caller's clock is never a fallback")
        await clock.releaseSleep.signal()
        assertEqual(CallSpeakerReadTiming(startHostTime: 2_000, endHostTime: 1_000).midpoint, nil)
        assertEqual(CallSpeakerReadTiming(startHostTime: 0, endHostTime: 1_000).midpoint, nil)
    }
}
