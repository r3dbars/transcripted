import Foundation

// MeetingCaptureAttempt is @MainActor (Sources/Meeting/MeetingCaptureSupport.swift),
// so this whole entry function runs isolated to MainActor — matching how its
// only real caller, MeetingCaptureBridge, is itself @MainActor.
@MainActor
func testMeetingCaptureAttempt() async {
    await runSuite("MeetingCaptureAttempt.resetIfCurrent resolves the current attempt") {
        let attempt = MeetingCaptureAttempt<Int>()
        let result = await withCheckedContinuation { (continuation: CheckedContinuation<Int, Never>) in
            let token = attempt.begin(continuation)
            let resolved = attempt.resetIfCurrent(token)
            guard resolved.count == 1 else {
                fatalError("expected the just-begun token to still be current with exactly one waiter")
            }
            resolved[0].resume(returning: 42)
        }
        assertEqual(
            result, 42,
            "resetIfCurrent should hand back the current attempt's continuation for the caller to resume"
        )
    }

    await runSuite("MeetingCaptureAttempt.reset unconditionally resolves the pending attempt") {
        let attempt = MeetingCaptureAttempt<Bool>()
        let result = await withCheckedContinuation { (continuation: CheckedContinuation<Bool, Never>) in
            _ = attempt.begin(continuation)
            let resolved = attempt.reset()
            guard resolved.count == 1 else {
                fatalError("expected reset() to return exactly the one pending continuation")
            }
            resolved[0].resume(returning: true)
        }
        assertTrue(
            result,
            "reset() must let a teardown path resume the continuation regardless of which token owns it"
        )
    }

    runSuite("MeetingCaptureAttempt.reset is a no-op when nothing is pending") {
        let attempt = MeetingCaptureAttempt<Bool>()
        assertTrue(
            attempt.reset().isEmpty,
            "reset() on a fresh (or already-drained) attempt must return no continuations, not trap"
        )
    }

    await runSuite("MeetingCaptureAttempt.resetIfCurrent rejects a token from a previous attempt") {
        let attempt = MeetingCaptureAttempt<Int>()
        let firstResult = await withCheckedContinuation { (continuation: CheckedContinuation<Int, Never>) in
            let firstToken = attempt.begin(continuation)
            // A caller must resolve any outstanding attempt before starting a
            // new one (MeetingCaptureBridge.startRecording() and, after this
            // change, stopAndAwaitFiles() both do this — or join it via
            // joinIfActive). Simulate a resolve-then-supersede here.
            for pending in attempt.reset() {
                pending.resume(returning: 1)
            }
            assertTrue(
                attempt.resetIfCurrent(firstToken).isEmpty,
                "a token from an already-resolved attempt must never resolve again"
            )
        }
        assertEqual(firstResult, 1)

        let secondResult = await withCheckedContinuation { (continuation: CheckedContinuation<Int, Never>) in
            _ = attempt.begin(continuation)
            for pending in attempt.reset() {
                pending.resume(returning: 2)
            }
        }
        assertEqual(
            secondResult, 2,
            "a fresh begin() after a resolved attempt should mint an independently resolvable token"
        )
    }

    await runSuite("MeetingCaptureAttempt.begin() silently displaces an unresolved prior attempt") {
        // This documents the exact hazard MeetingCaptureBridge.stopAndAwaitFiles
        // now avoids entirely by joining an active attempt (via joinIfActive)
        // instead of ever calling begin() while one is already in flight:
        // begin() itself still does not protect a caller who calls it anyway
        // without resetting (or joining) first. The type intentionally
        // mirrors its previous UUID-based behavior here (an unconditional
        // overwrite) rather than silently fixing the symptom at this layer,
        // because the caller is the one that knows whether an in-flight
        // attempt should be resumed with a real result, joined, or is safe
        // to discard.
        let attempt = MeetingCaptureAttempt<Int>()
        let firstBegan = ParakeetAsyncInterleavingGate()
        var firstToken: SupersessionEpoch.Token!
        var capturedFirstContinuation: CheckedContinuation<Int, Never>!

        let firstTask = Task { @MainActor () -> Int in
            await withCheckedContinuation { continuation in
                capturedFirstContinuation = continuation
                firstToken = attempt.begin(continuation)
                Task { await firstBegan.open() }
            }
        }

        await firstBegan.wait()

        let secondResult = await withCheckedContinuation { (continuation: CheckedContinuation<Int, Never>) in
            _ = attempt.begin(continuation)
            assertTrue(
                attempt.resetIfCurrent(firstToken).isEmpty,
                "the first attempt's token must be stale once a second begin() has superseded it"
            )
            for pending in attempt.reset() {
                pending.resume(returning: 2)
            }
        }
        assertEqual(secondResult, 2, "reset() resolves whichever attempt is currently stored (the second one)")

        // The attempt itself has now lost track of the first continuation —
        // resume it directly (bypassing the attempt) so this test doesn't
        // leak an unresumed CheckedContinuation, then prove it really was the
        // original, still-live continuation and not a trap.
        capturedFirstContinuation.resume(returning: 1)
        let firstResult = await firstTask.value
        assertEqual(
            firstResult, 1,
            "the displaced continuation is still resumable directly; only the attempt's own bookkeeping lost it"
        )
    }

    await runSuite("MeetingCaptureAttempt.joinIfActive returns false when nothing is in flight") {
        let attempt = MeetingCaptureAttempt<Int>()
        let result = await withCheckedContinuation { (continuation: CheckedContinuation<Int, Never>) in
            let joined = attempt.joinIfActive(continuation)
            assertFalse(joined, "joinIfActive must report false so the caller knows to begin() its own attempt")
            // Per contract, a failed join leaves `continuation` untouched —
            // the caller (MeetingCaptureBridge.stopAndAwaitFiles) is expected
            // to begin() with it instead. Do that here to resolve cleanly.
            let token = attempt.begin(continuation)
            for pending in attempt.resetIfCurrent(token) {
                pending.resume(returning: 7)
            }
        }
        assertEqual(result, 7)
    }

    await runSuite("MeetingCaptureAttempt.joinIfActive coalesces overlapping callers onto the same result via resetIfCurrent") {
        // Mirrors the bug MeetingCaptureBridge.stopAndAwaitFiles used to have:
        // two overlapping callers must observe the exact same eventual
        // result instead of the second one displacing (and never resuming)
        // the first, or minting its own token that makes the real completion
        // look stale. This suite exercises the "natural completion" path
        // (resetIfCurrent, matching the token from begin()) — the same
        // mechanism the bridge's real audio-completion callback uses.
        let attempt = MeetingCaptureAttempt<Int>()
        let firstBegan = ParakeetAsyncInterleavingGate()
        let secondJoined = ParakeetAsyncInterleavingGate()
        var firstToken: SupersessionEpoch.Token!

        let firstTask = Task { @MainActor () -> Int in
            await withCheckedContinuation { continuation in
                firstToken = attempt.begin(continuation)
                Task { await firstBegan.open() }
            }
        }
        await firstBegan.wait()

        let secondTask = Task { @MainActor () -> Int in
            await withCheckedContinuation { continuation in
                let joined = attempt.joinIfActive(continuation)
                assertTrue(joined, "a second caller must join the in-flight attempt instead of starting its own")
                Task { await secondJoined.open() }
            }
        }
        await secondJoined.wait()

        let waiters = attempt.resetIfCurrent(firstToken)
        assertEqual(
            waiters.count, 2,
            "resetIfCurrent must return the primary continuation plus every joined waiter"
        )
        for continuation in waiters {
            continuation.resume(returning: 99)
        }

        let firstResult = await firstTask.value
        let secondResult = await secondTask.value
        assertEqual(firstResult, 99, "the attempt-owning caller must see the shared result")
        assertEqual(secondResult, 99, "the joined caller must see the exact same shared result")
    }

    await runSuite("MeetingCaptureAttempt.joinIfActive coalesces overlapping callers onto the same result via reset") {
        // Same coalescing contract as above, but exercised through the
        // unconditional reset() path — this is what every teardown path
        // (deinit, a stale-attempt reset, and a timeout task's
        // resetIfCurrent-then-resume) relies on to resume every joined
        // waiter, not just the primary one.
        let attempt = MeetingCaptureAttempt<Bool>()
        let firstBegan = ParakeetAsyncInterleavingGate()
        let secondJoined = ParakeetAsyncInterleavingGate()

        let firstTask = Task { @MainActor () -> Bool in
            await withCheckedContinuation { continuation in
                _ = attempt.begin(continuation)
                Task { await firstBegan.open() }
            }
        }
        await firstBegan.wait()

        let secondTask = Task { @MainActor () -> Bool in
            await withCheckedContinuation { continuation in
                assertTrue(attempt.joinIfActive(continuation), "second caller should join")
                Task { await secondJoined.open() }
            }
        }
        await secondJoined.wait()

        let waiters = attempt.reset()
        assertEqual(waiters.count, 2, "reset() must drain the primary continuation plus every joined waiter")
        for continuation in waiters {
            continuation.resume(returning: false)
        }

        let firstResult = await firstTask.value
        let secondResult = await secondTask.value
        assertFalse(firstResult, "teardown must resume the attempt-owning caller")
        assertFalse(secondResult, "teardown must resume the joined caller with the same value")
    }

    await runSuite("MeetingCaptureAttempt.begin() clears any stale joined waiters from a prior attempt") {
        // Defensive: begin() always starts from a clean waiters list, even
        // though in practice a caller should only ever begin() when nothing
        // is active (joinIfActive covers the "already active" case).
        let attempt = MeetingCaptureAttempt<Int>()
        let firstBegan = ParakeetAsyncInterleavingGate()

        let firstTask = Task { @MainActor () -> Int in
            await withCheckedContinuation { continuation in
                _ = attempt.begin(continuation)
                Task { await firstBegan.open() }
            }
        }
        await firstBegan.wait()
        for pending in attempt.reset() {
            pending.resume(returning: 1)
        }
        _ = await firstTask.value

        let secondResult = await withCheckedContinuation { (continuation: CheckedContinuation<Int, Never>) in
            let token = attempt.begin(continuation)
            let waiters = attempt.resetIfCurrent(token)
            assertEqual(waiters.count, 1, "a freshly begun attempt must carry no leftover waiters")
            for pending in waiters {
                pending.resume(returning: 2)
            }
        }
        assertEqual(secondResult, 2)
    }

    await runSuite("MeetingCaptureAttempt.reset cancels its outstanding timeout task") {
        let attempt = MeetingCaptureAttempt<Bool>()
        let timeoutRan = TimeoutRanBox()
        let result = await withCheckedContinuation { (continuation: CheckedContinuation<Bool, Never>) in
            _ = attempt.begin(continuation)
            attempt.setTimeoutTask(Task { @MainActor in
                try? await Task.sleep(nanoseconds: 40_000_000)
                // `try?` swallows Task.sleep's CancellationError, so a
                // cancelled task must check `isCancelled` explicitly before
                // acting — exactly like every real timeout task in
                // MeetingCaptureBridge guards itself via resetIfCurrent's
                // token check, not by relying on the sleep throw alone.
                guard !Task.isCancelled else { return }
                timeoutRan.mark()
            })
            for pending in attempt.reset() {
                pending.resume(returning: false)
            }
        }
        assertFalse(result, "reset() should have resumed with the caller-provided value")
        try? await Task.sleep(nanoseconds: 120_000_000)
        assertFalse(timeoutRan.value, "reset() must cancel the outstanding timeout task so it never fires")
    }
}

@MainActor
private final class TimeoutRanBox {
    private(set) var value = false
    func mark() { value = true }
}
