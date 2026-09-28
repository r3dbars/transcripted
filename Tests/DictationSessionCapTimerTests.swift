import Foundation

// Behavior tests for the 5-minute dictation cap's clock
// (Sources/Dictation/DictationSessionCapTimer.swift). A fake clock stands in
// for real time, so the whole five minutes runs instantly.

@MainActor
func testDictationSessionCapTimer() async {
    await runSuite("Before the last 30 seconds it sleeps, and shows no countdown") {
        let fake = CapTimerFake(capSeconds: 300)
        fake.stopAtUptime = 1_000 + 200  // stop the run well before the warning window
        await DictationSessionCapTimer.run(fake.steps())

        assertTrue(fake.countdowns.isEmpty, "no countdown before the warning window")
        assertTrue(fake.sleeps.allSatisfy { $0 <= fake.pollSeconds }, "each sleep is capped at the poll interval")
    }

    await runSuite("In the last 30 seconds it counts down every second, then returns at the cap") {
        let fake = CapTimerFake(capSeconds: 300)
        await DictationSessionCapTimer.run(fake.steps())

        assertEqual(fake.clock, 1_000 + 300, "it runs until the cap and no longer")
        assertEqual(fake.countdowns.count, 30, "one countdown refresh per second of the last 30")
        assertEqual(fake.countdowns.first?.remaining, 30, "the countdown starts at 30 seconds left")
        assertEqual(fake.countdowns.last?.remaining, 1, "and ends at 1 second left")
        assertTrue(fake.sleeps.suffix(30).allSatisfy { $0 == 1 }, "inside the window it ticks every second")
    }

    await runSuite("VoiceOver is told once, the first time the countdown actually shows") {
        let fake = CapTimerFake(capSeconds: 300)
        fake.countdownHiddenForTicks = 3  // an Esc confirm prompt holds the notice slot briefly
        await DictationSessionCapTimer.run(fake.steps())

        let announced = fake.countdowns.filter(\.announce)
        assertEqual(announced.count, 4, "it keeps asking to announce until the countdown is on screen")
        assertEqual(fake.countdowns.filter { $0.announce && $0.shown }.count, 1, "and announces exactly once when it shows")
        assertFalse(fake.countdowns.dropFirst(4).contains(where: \.announce), "never again after it was shown")
    }

    await runSuite("Cancelling stops the timer at once") {
        let fake = CapTimerFake(capSeconds: 300)
        fake.cancelAfterSleeps = 2
        await DictationSessionCapTimer.run(fake.steps())

        assertEqual(fake.sleeps.count, 2, "no more sleeping once cancelled")
        assertTrue(fake.clock < 1_000 + 300, "it returned before the cap")
    }

    await runSuite("The cap counts from when recording began, not when the timer first runs") {
        // The controller starts the deadline before the timer task runs; a
        // late-running task must not get a longer cap.
        let fake = CapTimerFake(capSeconds: 300)
        fake.clock = 1_000 + 10  // the task first runs 10 seconds after the deadline started
        await DictationSessionCapTimer.run(fake.steps())

        assertEqual(fake.clock, 1_000 + 300, "the cap still lands 300 seconds after recording began")
    }
}

// MARK: - Fake

@MainActor
private final class CapTimerFake {
    struct Countdown: Equatable {
        var remaining: Double
        var announce: Bool
        var shown: Bool
    }

    let capSeconds: TimeInterval
    let pollSeconds: TimeInterval = 30
    var clock: TimeInterval = 1_000
    var sleeps: [TimeInterval] = []
    var countdowns: [Countdown] = []
    /// The countdown can't take the notice slot for this many refreshes.
    var countdownHiddenForTicks = 0
    /// Cancel after this many sleeps.
    var cancelAfterSleeps: Int?
    /// Treat the timer as cancelled once the clock reaches this.
    var stopAtUptime: TimeInterval?
    private let timeout: DictationSessionTimeout

    init(capSeconds: TimeInterval) {
        self.capSeconds = capSeconds
        var timeout = DictationSessionTimeout(timeoutInterval: capSeconds)
        timeout.start(at: 1_000)
        self.timeout = timeout
    }

    func steps() -> DictationSessionCapTimer.Steps {
        DictationSessionCapTimer.Steps(
            timeout: timeout,
            pollIntervalNanos: UInt64(pollSeconds * 1_000_000_000),
            uptime: { [unowned self] in self.clock },
            sleep: { [unowned self] nanoseconds in
                let seconds = Double(nanoseconds) / 1_000_000_000
                self.sleeps.append(seconds)
                self.clock += seconds
            },
            isCancelled: { [unowned self] in
                if let limit = self.cancelAfterSleeps, self.sleeps.count >= limit { return true }
                if let stop = self.stopAtUptime, self.clock >= stop { return true }
                return false
            },
            showCountdown: { [unowned self] remaining, announce in
                let shown = self.countdownHiddenForTicks <= 0
                self.countdownHiddenForTicks -= 1
                self.countdowns.append(Countdown(remaining: remaining.rounded(), announce: announce, shown: shown))
                return shown
            }
        )
    }
}
