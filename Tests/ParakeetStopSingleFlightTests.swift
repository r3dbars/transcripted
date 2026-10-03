// ParakeetStopSingleFlightTests.swift
//
// Behavior tests for two stop-latency promises:
// - The single-flight stop lifecycle runs the first caller's work inline, so a
//   stop pays no main-actor hop to start and none to resume its caller, and
//   a cancelled caller still finishes the stop's drain.
// - The decoder layer count cache only answers for the manager it was stored
//   for, and forgets it on clear.
// These run against fakes; none of this proves real AVAudioEngine, pinned-mic
// or FluidAudio behavior.

import Foundation

@MainActor
func testParakeetStopSingleFlight() async {
    await runInlineStopOrderSuites()
    runDecoderLayerCountCacheSuites()
}

@MainActor
private final class StopOrderLog {
    var entries: [String] = []
}

@MainActor
private func yieldUntilStopSettles(_ condition: () -> Bool) async -> Bool {
    for _ in 0..<10_000 {
        if condition() { return true }
        await Task.yield()
    }
    return condition()
}

@MainActor
private func runInlineStopOrderSuites() async {
    await runSuite("A stop runs its work before main-queue work already queued, and resumes its caller before work the stop queued") {
        let lifecycle = ParakeetSingleFlightLifecycle()
        let log = StopOrderLog()
        DispatchQueue.main.async {
            MainActor.assumeIsolated { log.entries.append("queued") }
        }
        await lifecycle.run {
            log.entries.append("work")
            // Like the pinned drain: wait on detached work, then come back.
            await Task.detached {}.value
            DispatchQueue.main.async {
                MainActor.assumeIsolated { log.entries.append("sink") }
            }
        }
        log.entries.append("caller")
        let settled = await yieldUntilStopSettles { log.entries.count == 4 }
        assertTrue(settled, "every step ran")
        assertEqual(log.entries, ["work", "queued", "caller", "sink"],
                    "the stop starts inline and its caller resumes without another main hop")
        assertFalse(lifecycle.isInProgress, "the stop clears once its work returns")
    }

    await runSuite("A cancelled caller still runs the stop's drain to the end") {
        let lifecycle = ParakeetSingleFlightLifecycle()
        var drained = false
        let caller = Task { @MainActor in
            withUnsafeCurrentTask { $0?.cancel() }
            await lifecycle.run {
                await Task.detached {}.value
                drained = true
            }
        }
        await caller.value
        assertTrue(drained, "the drain finished even though the caller was cancelled")
        assertFalse(lifecycle.isInProgress, "the stop clears after a cancelled caller")
    }

    await runSuite("Joined stops resume after the first stop's work, and the next stop runs fresh") {
        let lifecycle = ParakeetSingleFlightLifecycle()
        let drainGate = ParakeetAsyncInterleavingGate()
        let log = StopOrderLog()
        var runs = 0

        let first = Task { @MainActor in
            await lifecycle.run {
                runs += 1
                await drainGate.wait()
                log.entries.append("drained")
            }
            log.entries.append("first")
        }
        let started = await yieldUntilStopSettles { runs == 1 }
        assertTrue(started, "the first stop starts its drain")
        let joiners = (0..<2).map { index in
            Task { @MainActor in
                await lifecycle.run { runs += 1 }
                log.entries.append("joiner\(index)")
            }
        }
        for _ in 0..<50 { await Task.yield() }
        assertEqual(log.entries, [], "nobody returns before the drain finishes")
        assertTrue(lifecycle.isInProgress, "the stop stays visible while joiners wait")

        await drainGate.open()
        await first.value
        for joiner in joiners { await joiner.value }
        assertEqual(runs, 1, "only the first caller runs stop work")
        assertEqual(log.entries.first, "drained", "joiners never return ahead of the drain")
        assertEqual(Set(log.entries), ["drained", "first", "joiner0", "joiner1"], "every caller returned")
        assertFalse(lifecycle.isInProgress, "the stop clears once its work returns")

        await lifecycle.run { runs += 1 }
        assertEqual(runs, 2, "a stop after the finished one runs its own work")
    }
}

private final class FakeDecoderManager {}

private func runDecoderLayerCountCacheSuites() {
    runSuite("The decoder layer count is only returned for the manager it was stored for") {
        let managerA = FakeDecoderManager()
        let managerB = FakeDecoderManager()
        var cache = ParakeetDecoderLayerCountCache()
        assertNil(cache.count(for: managerA), "an empty cache answers nothing")

        cache.store(2, for: managerA)
        assertEqual(cache.count(for: managerA), 2, "the stored manager gets its count")
        assertNil(cache.count(for: managerB), "a different live manager never gets A's count")

        cache.store(4, for: managerB)
        assertEqual(cache.count(for: managerB), 4, "storing for B replaces A")
        assertNil(cache.count(for: managerA), "A no longer matches after B is stored")

        cache.clear()
        assertNil(cache.count(for: managerB), "teardown clears the count")
    }

    runSuite("The decoder layer count is dropped once its manager is released") {
        var cache = ParakeetDecoderLayerCountCache()
        do {
            let released = FakeDecoderManager()
            cache.store(2, for: released)
        }
        let replacement = FakeDecoderManager()
        assertNil(cache.count(for: replacement), "a released manager's count never leaks to a new one")
    }
}
