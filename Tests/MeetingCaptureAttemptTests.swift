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
            guard let resolved = attempt.resetIfCurrent(token) else {
                fatalError("expected the just-begun token to still be current")
            }
            resolved.resume(returning: 42)
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
            guard let resolved = attempt.reset() else {
                fatalError("expected reset() to return the pending continuation")
            }
            resolved.resume(returning: true)
        }
        assertTrue(
            result,
            "reset() must let a teardown path resume the continuation regardless of which token owns it"
        )
    }

    runSuite("MeetingCaptureAttempt.reset is a no-op when nothing is pending") {
        let attempt = MeetingCaptureAttempt<Bool>()
        assertNil(attempt.reset(), "reset() on a fresh (or already-drained) attempt must return nil, not trap")
    }

    await runSuite("MeetingCaptureAttempt.resetIfCurrent rejects a token from a previous attempt") {
        let attempt = MeetingCaptureAttempt<Int>()
        let firstResult = await withCheckedContinuation { (continuation: CheckedContinuation<Int, Never>) in
            let firstToken = attempt.begin(continuation)
            // A caller must resolve any outstanding attempt before starting a
            // new one (MeetingCaptureBridge.startRecording() and, after this
            // change, stopAndAwaitFiles() both do this). Simulate that here.
            attempt.reset()?.resume(returning: 1)
            assertNil(
                attempt.resetIfCurrent(firstToken),
                "a token from an already-resolved attempt must never resolve again"
            )
        }
        assertEqual(firstResult, 1)

        let secondResult = await withCheckedContinuation { (continuation: CheckedContinuation<Int, Never>) in
            _ = attempt.begin(continuation)
            attempt.reset()?.resume(returning: 2)
        }
        assertEqual(
            secondResult, 2,
            "a fresh begin() after a resolved attempt should mint an independently resolvable token"
        )
    }

    await runSuite("MeetingCaptureAttempt.begin() silently displaces an unresolved prior attempt") {
        // This documents the exact hazard MeetingCaptureBridge.stopAndAwaitFiles
        // now guards against: begin() does not protect a caller who forgets to
        // reset() first. The type intentionally mirrors its previous
        // UUID-based behavior here (an unconditional overwrite) rather than
        // silently fixing the symptom at this layer, because MeetingCaptureBridge
        // is the one place that knows whether an in-flight attempt should be
        // resumed with a real result or is safe to discard.
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
            assertNil(
                attempt.resetIfCurrent(firstToken),
                "the first attempt's token must be stale once a second begin() has superseded it"
            )
            attempt.reset()?.resume(returning: 2)
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
            attempt.reset()?.resume(returning: false)
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
