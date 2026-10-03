// DictationQueuedStartWaitTests.swift
// A remembered press wakes when the last take's state changes, not on a
// 50 ms poll, and still gives up at the same 2 s budget.

import Combine
import Foundation

@MainActor
func testDictationQueuedStartWait() async {
    await runSuite("A remembered press starts on the change, without waiting for a tick") {
        let rig = QueuedWaitRig()
        let wait = rig.start()
        await settleMainActor()
        assertEqual(rig.evaluations, 1, "one check when the press is remembered")
        assertNil(rig.result)

        rig.take.isFinishing = false
        await settleMainActor()
        assertEqual(rig.result, .start)
        assertEqual(rig.evaluations, 2, "the change woke exactly one more check")
        assertEqual(rig.clock, 0, "it reacted to the change, not to time passing")
        await wait.value
    }

    await runSuite("A @Published flip is read after it lands, not in its willSet") {
        // Reading the flag inside the change callback would see the old
        // value (still finishing) and keep waiting until the 2 s give-up.
        let rig = QueuedWaitRig()
        let wait = rig.start()
        await settleMainActor()
        rig.take.isFinishing = false
        await settleMainActor()
        assertEqual(rig.result, .start, "a flip to done starts, it doesn't wait out the budget")
        assertTrue(rig.deadline.requested.count == 1, "no second deadline was needed")
        await wait.value
    }

    await runSuite("With no change, the wait gives up at the 2 s budget, re-arming after an early wake") {
        let rig = QueuedWaitRig()
        let wait = rig.start()
        await settleMainActor()
        assertEqual(rig.deadline.requested, [2_000_000_000], "the first deadline is the whole budget")

        // The sleep ends early (as a real one can); time is left, so it re-arms.
        rig.clock = 1.95
        rig.deadline.fireLatest()
        await settleMainActor()
        assertNil(rig.result, "not given up before 2 s")
        assertEqual(rig.deadline.requested.count, 2)
        let rearmed = rig.deadline.requested.last ?? 0
        assertTrue(rearmed >= 49_000_000 && rearmed <= 51_000_000, "re-armed for the ~0.05 s left, got \(rearmed)")

        rig.clock = 1.999
        rig.deadline.fireLatest()
        await settleMainActor()
        assertNil(rig.result, "still not given up at 1.999 s")

        rig.clock = 2.0
        rig.deadline.fireLatest()
        await settleMainActor()
        assertEqual(rig.result, .giveUp)
        await wait.value
    }

    await runSuite("A take that ended on a message that can't give way drops the press") {
        let rig = QueuedWaitRig()
        rig.take.leftMessage = true
        let wait = rig.start()
        await settleMainActor()
        rig.take.isFinishing = false
        await settleMainActor()
        assertEqual(rig.result, .dropForMessage, "no start over the message")
        await wait.value
    }

    await runSuite("Cancelling the wait ends it with no decision and no more checks") {
        let rig = QueuedWaitRig()
        let wait = rig.start()
        await settleMainActor()
        wait.cancel()
        await wait.value
        let checks = rig.evaluations
        rig.take.isFinishing = false
        await settleMainActor()
        assertNil(rig.result, "a cancelled wait never starts or drops")
        assertTrue(rig.finished, "the wait returned")
        assertEqual(rig.evaluations, checks, "nothing checks after cancel")
        assertEqual(rig.watchesCancelled, 1, "the change watch is torn down")
    }

    await runSuite("A wait checks once per change and once at the deadline, not 20 times a second") {
        let rig = QueuedWaitRig()
        let wait = rig.start()
        await settleMainActor()
        for step in 1...3 {
            rig.clock = Double(step) * 0.4
            rig.take.isFinishing = true // a change that isn't the take finishing
            await settleMainActor()
        }
        rig.clock = 2.0
        rig.deadline.fireLatest()
        await settleMainActor()
        assertEqual(rig.result, .giveUp)
        assertEqual(rig.evaluations, 1 + 3 + 1)
        await wait.value
    }

    await runSuite("Without the press, the wait ends with no decision") {
        let rig = QueuedWaitRig()
        rig.pressGone = true
        let wait = rig.start()
        await wait.value
        assertNil(rig.result)
        assertTrue(rig.finished)
    }
}

/// Lets queued main-actor work run. Counts scheduler turns, not time.
@MainActor
private func settleMainActor() async {
    for _ in 0..<20 { await Task.yield() }
}

@MainActor
private final class QueuedTakeModel: ObservableObject {
    @Published var isFinishing = true
    var leftMessage = false
}

/// A deadline sleep the test ends by hand. A cancelled sleep returns at once.
@MainActor
private final class FakeDeadline {
    private(set) var requested: [UInt64] = []
    private var pending: [Int: CheckedContinuation<Void, Never>] = [:]
    private var nextID = 0

    func sleep(_ nanoseconds: UInt64) async {
        requested.append(nanoseconds)
        let id = nextID
        nextID += 1
        await withTaskCancellationHandler {
            await withCheckedContinuation { pending[id] = $0 }
        } onCancel: {
            Task { @MainActor in self.resume(id) }
        }
    }

    func fireLatest() {
        guard let id = pending.keys.max() else { return }
        resume(id)
    }

    private func resume(_ id: Int) {
        pending.removeValue(forKey: id)?.resume()
    }
}

@MainActor
private final class QueuedWaitRig {
    let take = QueuedTakeModel()
    let deadline = FakeDeadline()
    var clock: Double = 0
    var evaluations = 0
    var watchesCancelled = 0
    var pressGone = false
    var result: DictationQueuedStartPolicy.Decision?
    var finished = false

    func start() -> Task<Void, Never> {
        let deadline = self.deadline
        let steps = DictationQueuedStartWait.Steps(
            evaluate: { [unowned self] waited in
                guard !self.pressGone else { return nil }
                self.evaluations += 1
                return DictationQueuedStartPolicy.decision(
                    previousStillFinishing: self.take.isFinishing,
                    previousLeftMessage: self.take.leftMessage,
                    secondsWaited: waited
                )
            },
            watchChanges: { [unowned self] wake in
                let watch = self.take.$isFinishing.dropFirst().sink { _ in wake() }
                return { [unowned self] in
                    watch.cancel()
                    self.watchesCancelled += 1
                }
            },
            now: { [unowned self] in self.clock },
            requestedAt: 0,
            sleep: { await deadline.sleep($0) }
        )
        return Task { @MainActor in
            self.result = await DictationQueuedStartWait.run(steps)
            self.finished = true
        }
    }
}
