import Testing
@testable import TranscriptedWritingCore

@Suite("Intent future fusion")
struct IntentFutureFusionTests {
    @Test("Live typing can override the scene prior")
    func liveOverridesPrior() {
        let prior = [
            IntentFuture(kind: .accept, weight: 0.7),
            IntentFuture(kind: .commit, weight: 0.3),
        ]
        let live = [
            IntentFuture(kind: .clarify, weight: 0.8),
            IntentFuture(kind: .question, weight: 0.2),
        ]
        let fused = IntentFutureFusion.fuse(prior: prior, live: live)
        #expect(fused.first?.kind == .clarify)
        #expect(abs(fused.reduce(0) { $0 + $1.weight } - 1) < 0.0001)
    }

    @Test("Prior still contributes when live plan is ambiguous")
    func priorContributes() {
        let prior = [IntentFuture(kind: .commit, weight: 1)]
        let live = [
            IntentFuture(kind: .answer, weight: 0.5),
            IntentFuture(kind: .commit, weight: 0.5),
        ]
        let fused = IntentFutureFusion.fuse(prior: prior, live: live)
        #expect(fused.first?.kind == .commit)
    }
}
