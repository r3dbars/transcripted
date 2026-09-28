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
            now: { [unowned self] in self.clock },
            budget: budget
        )
    }
}
