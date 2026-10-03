import Foundation

func testDictationMuffleMachine() {
    runSuite("The muffle never cuts the originals before the tap reports sound, cuts once, and glides only after the cut") {
        var run = MuffleMachineRun()
        run.send(.micOpened, at: 0)
        run.send(.routeOpened(bluetooth: false), at: ms(1))
        run.signals = { _ in .none }
        run.run(until: ms(30))
        assertTrue(run.times(of: .cut).isEmpty, "no cut while the tap is silent")
        run.signals = { _ in muffleFlowing(quiet: true, delay: ms(1)) }
        run.run(until: ms(300))

        let cuts = run.times(of: .cut)
        assertEqual(cuts.count, 1, "exactly one cut per engage")
        assertTrue(run.cutsOnlyFromFlowingTicks, "every cut must come from a tick that reported sound flowing")
        let muffles = run.times(of: .setMuffled(true))
        assertEqual(muffles.count, 1, "exactly one glide down")
        if let cut = cuts.first, let muffle = muffles.first {
            assertTrue(cut >= ms(30), "cut should not land before sound flowed, cut at \(cut)")
            assertTrue(muffle >= cut + run.timing.glideAfterCutNanos, "glide at \(muffle) should be at least glideAfterCut after cut at \(cut)")
            assertTrue(run.index(of: .setMuffled(true))! > run.index(of: .cut)!, "glide comes after the cut")
        }
        assertEqual(run.machine.phase, .muffled, "should rest muffled while the mic is open")
    }

    runSuite("If the tap never delivers sound the muffle stands down as tap_silent without cutting") {
        var run = MuffleMachineRun()
        run.send(.micOpened, at: 0)
        run.send(.routeOpened(bluetooth: false), at: 0)
        run.signals = { _ in .none }
        run.run(until: ms(500))
        let closes = run.times(of: .closeRoute)
        assertEqual(closes.count, 1, "route should close once")
        assertTrue(run.contains(.report(.skipped(reason: "tap_silent"))), "should report tap_silent")
        assertTrue(run.times(of: .cut).isEmpty, "never cut when sound never flowed")
        assertTrue(run.times(of: .handBack).isEmpty, "nothing to hand back")
        if let close = closes.first {
            let wait = run.timing.firstSoundWaitNanos
            assertTrue(close >= wait, "should wait the full firstSoundWait before giving up, closed at \(close)")
            assertTrue(close <= wait + 2 * run.timing.pollNanos, "should give up right after firstSoundWait, closed at \(close)")
        }
        assertEqual(run.machine.phase, .idle, "back to idle after standing down")
    }

    runSuite("A Bluetooth route waits the longer Bluetooth first-sound window") {
        var run = MuffleMachineRun()
        run.send(.micOpened, at: 0)
        run.send(.routeOpened(bluetooth: true), at: 0)
        run.signals = { _ in .none }
        run.run(until: ms(500))
        let closes = run.times(of: .closeRoute)
        assertEqual(closes.count, 1, "route should close once")
        assertTrue(run.contains(.report(.skipped(reason: "tap_silent"))), "should report tap_silent")
        if let close = closes.first {
            let wait = run.timing.firstSoundWaitBluetoothNanos
            assertTrue(close >= wait, "Bluetooth should wait firstSoundWaitBluetooth, closed at \(close)")
            assertTrue(close <= wait + 2 * run.timing.pollNanos, "should give up right after the Bluetooth window, closed at \(close)")
        }

        var late = MuffleMachineRun()
        late.send(.micOpened, at: 0)
        late.send(.routeOpened(bluetooth: true), at: 0)
        let soundAt = (late.timing.firstSoundWaitNanos + late.timing.firstSoundWaitBluetoothNanos) / 2
        late.signals = { now in now >= soundAt ? muffleFlowing(quiet: true, delay: ms(1)) : .none }
        late.run(until: ms(500))
        assertEqual(late.times(of: .cut).count, 1, "Bluetooth sound arriving after the wired window but inside the Bluetooth one still engages")
        assertTrue(late.times(of: .closeRoute).isEmpty, "no stand-down when Bluetooth sound arrives in time")
    }

    runSuite("With a lagging copy the muffle waits for a quiet tick, then cuts") {
        var run = MuffleMachineRun()
        let lag = run.timing.quietCutAboveDelayNanos + ms(5)
        let quietAt = ms(40)
        run.send(.micOpened, at: 0)
        run.send(.routeOpened(bluetooth: false), at: 0)
        run.signals = { now in muffleFlowing(quiet: now >= quietAt, delay: lag) }
        run.run(until: ms(300))
        let cuts = run.times(of: .cut)
        assertEqual(cuts.count, 1, "one cut")
        if let cut = cuts.first {
            assertTrue(cut >= quietAt, "should not cut before the quiet moment, cut at \(cut)")
            assertTrue(cut <= quietAt + 2 * run.timing.pollNanos, "should cut on the first quiet tick, cut at \(cut)")
        }
        assertTrue(run.cutsOnlyFromQuietTicks, "the cut should come from a quiet tick")
    }

    runSuite("With a lagging copy and no quiet moment the muffle cuts when quietWait runs out") {
        var run = MuffleMachineRun()
        let lag = run.timing.quietCutAboveDelayNanos + ms(5)
        let flowAt = ms(5)
        run.send(.micOpened, at: 0)
        run.send(.routeOpened(bluetooth: false), at: 0)
        run.signals = { now in now >= flowAt ? muffleFlowing(quiet: false, delay: lag) : .none }
        run.run(until: ms(400))
        let cuts = run.times(of: .cut)
        assertEqual(cuts.count, 1, "one cut even without a quiet moment")
        if let cut = cuts.first {
            let wait = run.timing.quietWaitNanos
            assertTrue(cut >= flowAt + wait, "should wait quietWait after sound flowed, cut at \(cut)")
            assertTrue(cut <= flowAt + wait + 2 * run.timing.pollNanos, "should cut once quietWait runs out, cut at \(cut)")
        }
    }

    runSuite("With a small copy delay the muffle cuts on the first flowing tick") {
        // At or under quietCutAboveDelay counts as small.
        for small in [ms(1), muffleTestTiming.quietCutAboveDelayNanos] {
            var run = MuffleMachineRun()
            let flowAt = ms(8)
            run.send(.micOpened, at: 0)
            run.send(.routeOpened(bluetooth: false), at: 0)
            run.signals = { now in now >= flowAt ? muffleFlowing(quiet: false, delay: small) : .none }
            run.run(until: ms(200))
            let cuts = run.times(of: .cut)
            assertEqual(cuts.count, 1, "delay \(small): one cut")
            assertEqual(cuts.first, run.firstFlowingTickTime, "delay \(small): cut should land on the first flowing tick, not wait for quiet")
        }
    }

    runSuite("Closing the mic before the cut just closes the route") {
        // Waiting for sound.
        var silent = MuffleMachineRun()
        silent.send(.micOpened, at: 0)
        silent.send(.routeOpened(bluetooth: false), at: 0)
        silent.signals = { _ in .none }
        silent.run(until: ms(10))
        let closeBatch = silent.send(.micClosed, at: ms(11))
        assertTrue(closeBatch.contains(.closeRoute), "closing while waiting for sound should close the route")
        silent.run(until: ms(500))
        assertTrue(silent.times(of: .cut).isEmpty && silent.times(of: .handBack).isEmpty, "no cut or hand back when closing before the cut")
        assertEqual(silent.machine.phase, .idle, "idle after closing")

        // Waiting for quiet.
        var lagging = MuffleMachineRun()
        lagging.send(.micOpened, at: 0)
        lagging.send(.routeOpened(bluetooth: false), at: 0)
        let lag = muffleTestTiming.quietCutAboveDelayNanos + ms(5)
        lagging.signals = { _ in muffleFlowing(quiet: false, delay: lag) }
        lagging.run(until: ms(20))
        assertTrue(lagging.times(of: .cut).isEmpty, "still waiting for quiet")
        let quietClose = lagging.send(.micClosed, at: ms(21))
        assertTrue(quietClose.contains(.closeRoute), "closing while waiting for quiet should close the route")
        lagging.run(until: ms(500))
        assertTrue(lagging.times(of: .cut).isEmpty && lagging.times(of: .handBack).isEmpty, "no cut or hand back when closing while waiting for quiet")

        // Still opening the route.
        var opening = MuffleMachineRun()
        opening.send(.micOpened, at: 0)
        opening.send(.micClosed, at: ms(1))
        opening.send(.routeOpened(bluetooth: false), at: ms(2))
        opening.signals = { _ in muffleFlowing(quiet: true, delay: ms(1)) }
        opening.run(until: ms(500))
        assertTrue(opening.contains(.closeRoute), "closing while the route opens should still close it")
        assertTrue(opening.times(of: .cut).isEmpty && opening.times(of: .handBack).isEmpty, "no cut or hand back when the mic closed during opening")
    }

    runSuite("Closing the mic while muffled glides back, then hands back, then closes the route") {
        var run = MuffleMachineRun()
        run.engageToMuffled()
        let closedAt = run.now + ms(50)
        let batch = run.send(.micClosed, at: closedAt)
        assertTrue(batch.contains(.setMuffled(false)), "the glide back starts at once")
        assertFalse(batch.contains(.handBack), "no hand back before the glide back")
        assertFalse(batch.contains(.closeRoute), "no close before the glide back")
        run.run(until: closedAt + ms(500))
        let handBacks = run.times(of: .handBack, after: closedAt)
        let closes = run.times(of: .closeRoute, after: closedAt)
        assertEqual(handBacks.count, 1, "one hand back")
        assertEqual(closes.count, 1, "one close")
        if let handBack = handBacks.first, let close = closes.first {
            assertTrue(handBack >= closedAt + run.timing.releaseGlideNanos, "hand back at \(handBack) should wait releaseGlide after \(closedAt)")
            assertTrue(close >= handBack + run.timing.handBackSettleNanos, "close at \(close) should wait handBackSettle after \(handBack)")
        }
        assertEqual(run.machine.phase, .idle, "idle after the release")
    }

    runSuite("On a lagging route the hand back waits briefly for a quiet moment, then goes anyway") {
        let lag = muffleTestTiming.quietCutAboveDelayNanos + ms(5)

        var quiet = MuffleMachineRun()
        quiet.engageToMuffled()
        let closedAt = quiet.now + ms(10)
        let quietAt = closedAt + quiet.timing.releaseGlideNanos + ms(30)
        quiet.signals = { now in muffleFlowing(quiet: now >= quietAt, delay: lag) }
        quiet.send(.micClosed, at: closedAt)
        quiet.run(until: closedAt + ms(1_000))
        let quietHandBacks = quiet.times(of: .handBack, after: closedAt)
        assertEqual(quietHandBacks.count, 1, "one hand back")
        if let handBack = quietHandBacks.first {
            assertTrue(handBack >= quietAt, "hand back at \(handBack) should wait for the quiet moment at \(quietAt)")
            assertTrue(handBack <= quietAt + 2 * quiet.timing.pollNanos, "hand back right after the quiet moment, at \(handBack)")
        }

        var loud = MuffleMachineRun()
        loud.engageToMuffled()
        let loudClosedAt = loud.now + ms(10)
        loud.signals = { _ in muffleFlowing(quiet: false, delay: lag) }
        loud.send(.micClosed, at: loudClosedAt)
        loud.run(until: loudClosedAt + ms(2_000))
        let loudHandBacks = loud.times(of: .handBack, after: loudClosedAt)
        assertEqual(loudHandBacks.count, 1, "one hand back even with no quiet moment")
        if let handBack = loudHandBacks.first {
            let earliest = loudClosedAt + loud.timing.releaseGlideNanos + loud.timing.handBackQuietWaitNanos
            assertTrue(handBack >= earliest, "without quiet the hand back waits the full budget, at \(handBack)")
            assertTrue(handBack <= earliest + 2 * loud.timing.pollNanos, "and then goes, at \(handBack)")
        }
        assertEqual(loud.machine.phase, .idle, "idle after the release")

        var reopened = MuffleMachineRun()
        reopened.engageToMuffled()
        let reopenClosedAt = reopened.now + ms(10)
        reopened.signals = { _ in muffleFlowing(quiet: false, delay: lag) }
        reopened.send(.micClosed, at: reopenClosedAt)
        reopened.run(until: reopenClosedAt + reopened.timing.releaseGlideNanos + ms(20))
        let batch = reopened.send(.micOpened, at: reopened.now)
        assertTrue(batch.contains(.setMuffled(true)), "reopening while waiting to hand back glides down again")
        assertFalse(batch.contains(.handBack) || batch.contains(.cut) || batch.contains(.closeRoute), "with no hand back, cut or close")
        assertEqual(reopened.machine.phase, .muffled, "back to muffled")
    }

    runSuite("Closing the mic after the cut but before the glide hands back at once") {
        var run = MuffleMachineRun()
        run.send(.micOpened, at: 0)
        run.send(.routeOpened(bluetooth: false), at: 0)
        run.signals = { _ in muffleFlowing(quiet: true, delay: ms(1)) }
        run.run(until: ms(300)) { phase in if case .cutting = phase { return true } else { return false } }
        guard case .cutting = run.machine.phase else {
            assertTrue(false, "never reached the cutting phase, at \(run.machine.phase)")
            return
        }
        let closedAt = run.now + 1
        let batch = run.send(.micClosed, at: closedAt)
        assertTrue(batch.contains(.handBack), "closing during the cut should hand back at once")
        run.run(until: closedAt + ms(300))
        assertTrue(run.times(of: .setMuffled(true)).isEmpty, "the glide down never starts")
        assertEqual(run.times(of: .closeRoute).count, 1, "the route closes after the hand back")
        assertEqual(run.machine.phase, .idle, "idle afterwards")
    }

    runSuite("Reopening the mic during the glide back just glides down again") {
        var run = MuffleMachineRun()
        run.engageToMuffled()
        let closedAt = run.now + ms(20)
        run.send(.micClosed, at: closedAt)
        let reopenAt = closedAt + run.timing.releaseGlideNanos / 2
        let batch = run.send(.micOpened, at: reopenAt)
        assertEqual(batch.filter { !$0.isWake }, [.setMuffled(true)], "reopen during the glide back should only glide down")
        run.run(until: reopenAt + ms(500))
        assertTrue(run.times(of: .handBack, after: reopenAt).isEmpty, "no hand back after reopening")
        assertTrue(run.times(of: .closeRoute, after: reopenAt).isEmpty, "no close after reopening")
        assertTrue(run.times(of: .cut, after: reopenAt).isEmpty, "no second cut")
        assertTrue(run.times(of: .openRoute, after: reopenAt).isEmpty, "no second open")
        assertEqual(run.machine.phase, .muffled, "back to muffled")
    }

    runSuite("Reopening the mic during the hand back cuts again instead of reopening the route") {
        var run = MuffleMachineRun()
        run.engageToMuffled()
        let closedAt = run.now + ms(20)
        run.send(.micClosed, at: closedAt)
        run.run(until: closedAt + ms(500)) { phase in if case .handingBack = phase { return true } else { return false } }
        guard case .handingBack = run.machine.phase else {
            assertTrue(false, "never reached the hand back phase, at \(run.machine.phase)")
            return
        }
        let reopenAt = run.now + 1
        let batch = run.send(.micOpened, at: reopenAt)
        assertTrue(batch.contains(.cut), "reopen during the hand back should cut again")
        assertFalse(batch.contains(.openRoute), "the route is still open, don't reopen it")
        run.run(until: reopenAt + ms(500))
        assertTrue(run.times(of: .closeRoute, after: closedAt).isEmpty, "the route never closes")
        let glide = run.times(of: .setMuffled(true), after: reopenAt)
        assertEqual(glide.count, 1, "glides down again after the new cut")
        if let glide = glide.first {
            assertTrue(glide >= reopenAt + run.timing.glideAfterCutNanos, "new glide at \(glide) should wait glideAfterCut after \(reopenAt)")
        }
        assertEqual(run.machine.phase, .muffled, "muffled again")
    }

    runSuite("Losing the route from any active phase closes it, reports stopped and returns to idle") {
        let phases: [(String, (inout MuffleMachineRun) -> Void)] = [
            ("opening", { run in run.send(.micOpened, at: 0) }),
            ("awaitingSound", { run in
                run.send(.micOpened, at: 0)
                run.send(.routeOpened(bluetooth: false), at: 0)
                run.signals = { _ in .none }
                run.run(until: ms(5))
            }),
            ("awaitingQuiet", { run in
                run.send(.micOpened, at: 0)
                run.send(.routeOpened(bluetooth: false), at: 0)
                let lag = run.timing.quietCutAboveDelayNanos + ms(5)
                run.signals = { _ in muffleFlowing(quiet: false, delay: lag) }
                run.run(until: ms(20))
            }),
            ("cutting", { run in
                run.send(.micOpened, at: 0)
                run.send(.routeOpened(bluetooth: false), at: 0)
                run.signals = { _ in muffleFlowing(quiet: true, delay: ms(1)) }
                run.run(until: ms(300)) { phase in if case .cutting = phase { return true } else { return false } }
            }),
            ("muffled", { run in run.engageToMuffled() }),
            ("releasing", { run in
                run.engageToMuffled()
                run.send(.micClosed, at: run.now + ms(10))
            }),
            ("handingBack", { run in
                run.engageToMuffled()
                run.send(.micClosed, at: run.now + ms(10))
                run.run(until: run.now + ms(500)) { phase in if case .handingBack = phase { return true } else { return false } }
            }),
        ]
        for (label, setup) in phases {
            var run = MuffleMachineRun()
            setup(&run)
            assertTrue(run.machine.phase != .idle, "\(label): setup should leave the machine active")
            let batch = run.send(.routeLost(reason: "device_gone"), at: run.now + 1)
            assertTrue(batch.contains(.closeRoute), "\(label): route lost should close the route")
            assertTrue(batch.contains(.report(.stopped(reason: "device_gone"))), "\(label): route lost should report stopped, got \(batch)")
            assertEqual(run.machine.phase, .idle, "\(label): idle after losing the route")
        }
    }

    runSuite("A route that fails to open closes and reports skipped") {
        var run = MuffleMachineRun()
        run.send(.micOpened, at: 0)
        let batch = run.send(.routeFailed(reason: "tap_create_failed"), at: ms(1))
        assertTrue(batch.contains(.closeRoute), "a failed open should close what was built")
        assertTrue(batch.contains { if case .report(.skipped) = $0 { return true } else { return false } }, "a failed open should report skipped, got \(batch)")
        assertTrue(run.times(of: .cut).isEmpty, "never cut")
        assertEqual(run.machine.phase, .idle, "idle after the failed open")
    }

    runSuite("In idle, mic closed, ticks and route lost do nothing, and a repeated mic open while engaged does nothing") {
        var machine = DictationMuffleMachine(timing: muffleTestTiming)
        assertEqual(machine.handle(.micClosed, now: 0), [], "mic closed in idle")
        assertEqual(machine.handle(.tick(muffleFlowing(quiet: true, delay: ms(1))), now: ms(1)), [], "tick in idle")
        assertEqual(machine.handle(.tick(.none), now: ms(2)), [], "silent tick in idle")
        assertEqual(machine.handle(.routeLost(reason: "device_gone"), now: ms(3)), [], "route lost in idle")
        assertEqual(machine.phase, .idle, "still idle")

        var run = MuffleMachineRun()
        run.engageToMuffled()
        assertEqual(run.send(.micOpened, at: run.now + 1), [], "repeated mic open while muffled")
        assertEqual(run.machine.phase, .muffled, "still muffled")

        var opening = MuffleMachineRun()
        opening.send(.micOpened, at: 0)
        assertEqual(opening.send(.micOpened, at: 1).filter { !$0.isWake }, [], "repeated mic open while opening should not open twice")

        var waiting = MuffleMachineRun()
        waiting.send(.micOpened, at: 0)
        waiting.send(.routeOpened(bluetooth: false), at: 0)
        waiting.signals = { _ in .none }
        waiting.run(until: ms(5))
        assertEqual(waiting.send(.micOpened, at: ms(6)).filter { !$0.isWake }, [], "repeated mic open while waiting for sound")
    }

    runSuite("After a full engage and release, the next mic open starts over with openRoute") {
        var run = MuffleMachineRun()
        run.engageToMuffled()
        let closedAt = run.now + ms(10)
        run.send(.micClosed, at: closedAt)
        run.run(until: closedAt + ms(500))
        assertEqual(run.machine.phase, .idle, "idle after the first take")
        let reopenAt = run.now + ms(100)
        let batch = run.send(.micOpened, at: reopenAt)
        assertTrue(batch.contains(.openRoute), "a new take opens the route again")
        run.send(.routeOpened(bluetooth: false), at: reopenAt + ms(1))
        run.run(until: reopenAt + ms(300))
        assertEqual(run.times(of: .cut, after: reopenAt).count, 1, "the second take cuts exactly once")
        assertEqual(run.times(of: .cut).count, 2, "one cut per take")
        assertEqual(run.machine.phase, .muffled, "muffled again")
    }

    runSuite("The default muffle timing engages and releases end to end") {
        var run = MuffleMachineRun(timing: DictationMuffleTiming())
        run.engageToMuffled()
        let closedAt = run.now + ms(10)
        run.send(.micClosed, at: closedAt)
        run.run(until: closedAt + ms(2_000))
        assertEqual(run.times(of: .cut).count, 1, "one cut")
        assertEqual(run.times(of: .handBack).count, 1, "one hand back")
        assertEqual(run.times(of: .closeRoute).count, 1, "one close")
        assertEqual(run.machine.phase, .idle, "idle at the end")
    }
}

// MARK: - Virtual clock driver

private func ms(_ value: UInt64) -> UInt64 { value * 1_000_000 }

/// Distinct values so a hard-coded default can't pass for an injected one.
private let muffleTestTiming = DictationMuffleTiming(
    pollNanos: 1_000_000,
    firstSoundWaitNanos: 50_000_000,
    firstSoundWaitBluetoothNanos: 120_000_000,
    quietCutAboveDelayNanos: 10_000_000,
    quietWaitNanos: 80_000_000,
    glideAfterCutNanos: 7_000_000,
    releaseGlideNanos: 40_000_000,
    handBackSettleNanos: 9_000_000
)

private func muffleFlowing(quiet: Bool, delay: UInt64?) -> DictationMuffleSignals {
    DictationMuffleSignals(soundFlowing: true, quiet: quiet, copyDelayNanos: delay)
}

private extension DictationMuffleEffect {
    var isWake: Bool {
        if case .wake = self { return true }
        return false
    }
}

private struct MuffleMachineLogEntry {
    var time: UInt64
    var input: DictationMuffleInput
    var effect: DictationMuffleEffect
}

/// Feeds the machine like a single-timer host would: each batch's wake
/// request replaces the pending one, and a tick is delivered at that time
/// carrying whatever `signals` says the tap reports then.
private struct MuffleMachineRun {
    var machine: DictationMuffleMachine
    var timing: DictationMuffleTiming { machine.timing }
    var signals: (UInt64) -> DictationMuffleSignals = { _ in .none }
    private(set) var now: UInt64 = 0
    private(set) var pendingWake: UInt64?
    private(set) var log: [MuffleMachineLogEntry] = []
    private(set) var tickSignals: [(time: UInt64, signals: DictationMuffleSignals)] = []

    init(timing: DictationMuffleTiming = muffleTestTiming) {
        machine = DictationMuffleMachine(timing: timing)
    }

    @discardableResult
    mutating func send(_ input: DictationMuffleInput, at time: UInt64) -> [DictationMuffleEffect] {
        now = max(now, time)
        if case .tick(let s) = input { tickSignals.append((now, s)) }
        let effects = machine.handle(input, now: now)
        for effect in effects { log.append(MuffleMachineLogEntry(time: now, input: input, effect: effect)) }
        let wakes = effects.compactMap { effect -> UInt64? in
            if case .wake(let at) = effect { return at }
            return nil
        }
        if let wake = wakes.min() { pendingWake = wake }
        return effects
    }

    mutating func run(until end: UInt64, stopWhen: (DictationMufflePhase) -> Bool = { _ in false }) {
        var steps = 0
        while let wake = pendingWake, wake <= end {
            if stopWhen(machine.phase) { return }
            steps += 1
            if steps > 200_000 {
                assertTrue(false, "machine kept asking for wakes without time moving, stuck at \(now)")
                return
            }
            pendingWake = nil
            let at = max(wake, now)
            send(.tick(signals(at)), at: at)
        }
        if stopWhen(machine.phase) { return }
        now = max(now, end)
    }

    mutating func engageToMuffled() {
        let start = now
        send(.micOpened, at: start)
        send(.routeOpened(bluetooth: false), at: start + ms(1))
        signals = { _ in muffleFlowing(quiet: true, delay: ms(1)) }
        run(until: start + ms(400)) { $0 == .muffled }
        assertEqual(machine.phase, .muffled, "engage should reach muffled")
    }

    func times(of effect: DictationMuffleEffect, after: UInt64 = 0) -> [UInt64] {
        log.filter { $0.effect == effect && $0.time >= after }.map(\.time)
    }

    func index(of effect: DictationMuffleEffect) -> Int? {
        log.firstIndex { $0.effect == effect }
    }

    func contains(_ effect: DictationMuffleEffect) -> Bool {
        log.contains { $0.effect == effect }
    }

    var firstFlowingTickTime: UInt64? {
        tickSignals.first { $0.signals.soundFlowing }?.time
    }

    var cutsOnlyFromFlowingTicks: Bool {
        log.filter { $0.effect == .cut }.allSatisfy { entry in
            if case .tick(let s) = entry.input { return s.soundFlowing }
            return false
        }
    }

    var cutsOnlyFromQuietTicks: Bool {
        log.filter { $0.effect == .cut }.allSatisfy { entry in
            if case .tick(let s) = entry.input { return s.soundFlowing && s.quiet }
            return false
        }
    }
}
