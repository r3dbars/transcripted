import Foundation

@MainActor
func testLiveTranscriptPrewarmPolicy() async {
    typealias Policy = LiveTranscriptPrewarmPolicy

    runSuite("Live transcript prewarm never compiles a second copy beside the dictation preview's") {
        assertEqual(Policy.step(preview: .ready, dictation: .loaded, waited: .zero), .skip,
                    "skips when the dictation preview already holds the model")
        assertEqual(Policy.step(preview: .preparing, dictation: .loaded, waited: .seconds(600)), .wait(.seconds(1)),
                    "waits while the preview loads the same model")
        assertEqual(Policy.step(preview: .off, dictation: .loading, waited: .zero), .wait(.seconds(5)),
                    "waits while the dictation model is still loading, so the two compiles never overlap")
        assertEqual(Policy.step(preview: .off, dictation: .loaded, waited: .seconds(60)), .wait(.seconds(5)),
                    "waits while a take holds a loaded dictation model")
    }

    runSuite("Live transcript prewarm still warms the first meeting when nothing is coming") {
        assertEqual(Policy.step(preview: .off, dictation: .other, waited: .zero), .load,
                    "doesn't wait on a dictation model that failed or isn't loading")
        assertEqual(Policy.step(preview: .off, dictation: .loading, waited: .seconds(180)), .load,
                    "stops waiting at the limit")
        assertEqual(Policy.step(preview: .notAttached, dictation: .loading, waited: .zero), .load,
                    "loads as before when the preview is off or the launch is automated")
        assertEqual(Policy.step(preview: .unavailable, dictation: .loaded, waited: .zero), .load,
                    "loads when the preview's own load failed")
    }

    await runSuite("Live transcript prewarm settles in bounded virtual time") {
        typealias State = (preview: Policy.Preview, dictation: Policy.Dictation)

        func drive(_ timeline: @escaping (Duration) -> State, cancelAt: Duration? = nil) async -> (Policy.Outcome, Duration) {
            var clock: Duration = .zero
            let outcome = await Policy.settle(
                state: { timeline(clock) },
                sleep: { clock += $0 },
                isCancelled: { cancelAt.map { clock >= $0 } ?? false }
            )
            return (outcome, clock)
        }

        let warm = await drive { _ in (.ready, .loaded) }
        assertEqual(warm.0, .skipped, "a warm launch with the preview ready skips")
        assertEqual(warm.1, .zero, "and doesn't wait")

        // After an OS update: the dictation model compiles for 40 s, then the
        // preview compiles the EOU model for 20 s and ends ready.
        let osUpdate = await drive { time in
            if time < .seconds(40) { return (.off, .loading) }
            if time < .seconds(60) { return (.preparing, .loaded) }
            return (.ready, .loaded)
        }
        assertEqual(osUpdate.0, .skipped, "an OS update waits for the dictation model, then skips")
        assertTrue(osUpdate.1 >= .seconds(60), "it waited out both compiles")

        let neverLoads = await drive { _ in (.off, .other) }
        assertEqual(neverLoads.0, .load, "a dictation model that never loads doesn't hold the prewarm")
        assertEqual(neverLoads.1, .zero)

        let stuck = await drive { _ in (.off, .loading) }
        assertEqual(stuck.0, .load, "a dictation model stuck loading forever loads at the limit")
        assertEqual(stuck.1, .seconds(180), "after exactly the limit")

        let cancelled = await drive({ _ in (.off, .loading) }, cancelAt: .seconds(30))
        assertEqual(cancelled.0, .cancelled, "turning Live transcript off mid-wait returns without loading")
    }
}
