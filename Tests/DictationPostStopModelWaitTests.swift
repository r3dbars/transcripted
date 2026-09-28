import Foundation

// Behavior tests for the second stage of stopping a dictation
// (Sources/Dictation/DictationPostStopModelWait.swift): wait for the voice model
// after the take is checkpointed. A fake clock stands in for real time, so
// "waits out the budget" runs instantly.

@MainActor
func testDictationPostStopModelWait() async {
    await runSuite("A loaded model means no wait and no loading overlay") {
        let fake = ModelWaitFake(loaded: true)
        let result = await DictationPostStopModelWait.run(fake.steps())

        assertEqual(result.outcome, .alreadyLoaded, "nothing to wait for")
        assertEqual(fake.events, [], "no overlay, no initialization, no wait")
        assertNil(result.marks.waitStartedAt, "no wait mark when nothing waited")
    }

    await runSuite("A model nobody is loading gets its load kicked, then the stop goes on") {
        let fake = ModelWaitFake(loaded: false, states: [.notLoaded, .loading])
        fake.loadsAfterWaits = 2
        let result = await DictationPostStopModelWait.run(fake.steps())

        assertEqual(result.outcome, .ready, "the model loaded during the wait")
        assertEqual(fake.events.filter { $0 == "request load" }.count, 1,
                    "the load is requested once, when nothing was loading it")
        assertEqual(fake.events.first, "wait started", "the post-stop overlay goes up before any waiting")
        assertNotNil(result.marks.readyAt, "a successful wait records when the model became ready")
    }

    await runSuite("A download already in progress is joined, not restarted") {
        let fake = ModelWaitFake(loaded: false, states: [.downloading(progress: 0.4)])
        fake.loadsAfterWaits = 1
        let result = await DictationPostStopModelWait.run(fake.steps())

        assertEqual(result.outcome, .ready, "the in-flight download finished")
        assertFalse(fake.events.contains("request load"), "never kick a second load while one is running")
    }

    await runSuite("A failed load gives up right away instead of waiting out the budget") {
        let fake = ModelWaitFake(loaded: false, states: [.failed("model missing")])
        let result = await DictationPostStopModelWait.run(fake.steps())

        assertEqual(result.outcome, .unavailable, "the saved-recording message comes straight away")
        assertFalse(fake.events.contains("wait for progress"), "no waiting once the load has failed")
        assertFalse(fake.events.contains("request load"), "the stop path doesn't retry a failed load; the audio is already saved")
    }

    await runSuite("A model that never loads stops at the budget") {
        let fake = ModelWaitFake(loaded: false, states: [.loading])
        fake.loadsAfterWaits = nil  // never loads
        let result = await DictationPostStopModelWait.run(fake.steps())

        assertEqual(result.outcome, .unavailable, "the wait is bounded")
        assertTrue(fake.clock >= 1_000 + fake.budget, "it gave up only once the budget ran out")
        assertTrue(fake.events.filter { $0 == "wait for progress" }.count >= 1, "it did wait before giving up")
    }

    await runSuite("A session that ends during the wait does nothing more") {
        let fake = ModelWaitFake(loaded: false, states: [.loading])
        fake.loadsAfterWaits = nil
        fake.sessionEndsAfterWaits = 1
        let result = await DictationPostStopModelWait.run(fake.steps())

        assertEqual(result.outcome, .abandoned, "no error or telemetry for a session that is gone")
        assertEqual(fake.events.filter { $0 == "wait for progress" }.count, 1, "it stops waiting as soon as the session ends")
    }

    await runSuite("A session that ends in the same wait the model loads is still abandoned") {
        // The session check comes before the loaded check after the wait, so a
        // dead session never goes on to transcribe.
        let fake = ModelWaitFake(loaded: false, states: [.loading])
        fake.loadsAfterWaits = 1
        fake.sessionEndsAfterWaits = 1
        let result = await DictationPostStopModelWait.run(fake.steps())

        assertEqual(result.outcome, .abandoned, "a session that is gone must not transcribe even if the model just loaded")
    }

    await runSuite("A cached model gets its load kicked; a ready-but-not-loaded one is joined") {
        let cached = ModelWaitFake(loaded: false, states: [.cached])
        _ = await DictationPostStopModelWait.run(cached.steps())
        assertEqual(cached.events.filter { $0 == "request load" }.count, 1, "a cached model still needs loading")

        let ready = ModelWaitFake(loaded: false, states: [.ready])
        _ = await DictationPostStopModelWait.run(ready.steps())
        assertFalse(ready.events.contains("request load"), "a model already reporting ready is waited on, not re-requested")
    }

    await runSuite("The deadline comes from time since boot; the marks come from wall-clock time") {
        // The router's waiter compares against systemUptime, so a deadline built
        // from wall-clock time would never arrive.
        let fake = ModelWaitFake(loaded: false, states: [.loading])
        fake.wallClockOffset = 800_000_000
        fake.loadsAfterWaits = 1
        let result = await DictationPostStopModelWait.run(fake.steps())

        assertEqual(fake.deadlinesSeen, [1_000 + fake.budget], "the deadline is uptime plus the budget")
        assertTrue((result.marks.waitStartedAt ?? 0) >= 800_000_000, "the wait-start mark is wall-clock time")
        assertTrue((result.marks.readyAt ?? 0) >= 800_000_000, "the ready mark is wall-clock time")
    }

    await runSuite("A wait that ends without a model still records when it started") {
        let fake = ModelWaitFake(loaded: false, states: [.failed("model missing")])
        let result = await DictationPostStopModelWait.run(fake.steps())

        assertEqual(result.outcome, .unavailable, "the load failed")
        assertNotNil(result.marks.waitStartedAt, "stop-latency telemetry still gets the wait start")
        assertNil(result.marks.readyAt, "no ready mark without a model")
    }

    await runSuite("The overlay is refreshed on every pass while waiting") {
        let fake = ModelWaitFake(loaded: false, states: [.loading])
        fake.loadsAfterWaits = 3
        _ = await DictationPostStopModelWait.run(fake.steps())

        assertEqual(fake.events.filter { $0 == "still waiting" }.count, 3,
                    "each pass refreshes the post-stop loading overlay")
    }
}

// MARK: - Fake

@MainActor
private final class ModelWaitFake {
    var events: [String] = []
    var loaded: Bool
    var states: [ParakeetModelState]
    /// The model reports loaded after this many progress waits; nil means never.
    var loadsAfterWaits: Int? = 1
    /// The session ends after this many progress waits; nil means it never does.
    var sessionEndsAfterWaits: Int?
    var clock: TimeInterval = 1_000
    /// Added to the wall clock so tests can tell it apart from uptime.
    var wallClockOffset: TimeInterval = 0
    var deadlinesSeen: [TimeInterval] = []
    let budget: TimeInterval = 30
    private var waits = 0

    init(loaded: Bool, states: [ParakeetModelState] = [.notLoaded]) {
        self.loaded = loaded
        self.states = states
    }

    func steps() -> DictationPostStopModelWait.Steps {
        DictationPostStopModelWait.Steps(
            isCurrent: { [unowned self] in
                guard let ends = self.sessionEndsAfterWaits else { return true }
                return self.waits < ends
            },
            isModelLoaded: { [unowned self] in self.loaded },
            modelState: { [unowned self] in
                self.states[min(self.waits, self.states.count - 1)]
            },
            requestModelInitialization: { [unowned self] in self.events.append("request load") },
            waitForProgress: { [unowned self] deadline in
                self.events.append("wait for progress")
                self.deadlinesSeen.append(deadline)
                self.waits += 1
                // Each wait takes 10 seconds of fake time, never past the deadline.
                self.clock = min(self.clock + 10, deadline)
                if let loadsAfter = self.loadsAfterWaits, self.waits >= loadsAfter {
                    self.loaded = true
                }
            },
            waitStarted: { [unowned self] in self.events.append("wait started") },
            stillWaiting: { [unowned self] in self.events.append("still waiting") },
            uptime: { [unowned self] in self.clock },
            now: { [unowned self] in self.clock + self.wallClockOffset },
            budget: budget
        )
    }
}
