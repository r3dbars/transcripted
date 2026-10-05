import Foundation
import Testing
@testable import TranscriptedWritingRuntime

@Suite("Model settlement without polling", .timeLimit(.minutes(1)))
struct ModelSettlementTests {
    @Test("Finishing releases all waiters, including waiters admitted after completion")
    func finishesAllWaiters() async {
        let settlement = ModelSettlement()
        let waiters = (0..<8).map { _ in Task { await settlement.wait() } }
        while settlement.waiterCount != waiters.count { await Task.yield() }
        settlement.finish()
        for waiter in waiters { await waiter.value }
        #expect(settlement.waiterCount == 0)
        await settlement.wait()
        settlement.finish()
    }

    @Test("Cancelling one waiter leaves every other waiter pending")
    func cancellationIsIndividual() async {
        let settlement = ModelSettlement()
        let cancelled = Task { await settlement.wait() }
        let other = Task { await settlement.wait() }
        while settlement.waiterCount != 2 { await Task.yield() }
        cancelled.cancel()
        await cancelled.value
        #expect(settlement.waiterCount == 1)
        settlement.finish()
        await other.value
    }

    @Test("Cancellation before or during admission cannot strand a waiter")
    func cancellationAdmissionRace() async {
        let settlement = ModelSettlement()
        let waiters = (0..<100).map { _ in
            let waiter = Task { await settlement.wait() }
            waiter.cancel()
            return waiter
        }
        for waiter in waiters { await waiter.value }
        #expect(settlement.waiterCount == 0)
    }

    @Test("Finishing an old generation twice cannot release its successor's waiters")
    func generationsAreIndependent() async {
        let old = ModelSettlement(), current = ModelSettlement()
        old.finish()
        let waiter = Task { await current.wait() }
        while current.waiterCount != 1 { await Task.yield() }
        old.finish()
        #expect(current.waiterCount == 1)
        current.finish()
        await waiter.value
    }
}
