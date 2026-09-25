import Testing
@testable import TranscriptedWritingCore

@Suite("Intent futures")
struct IntentFuturesTests {
    private func replyScene(_ text: String) -> ScreenScene.Scene {
        .init(
            mode: .replying,
            conversationTurns: [.init(speaker: .other, text: text)],
            referenceSnippets: []
        )
    }

    @Test("A commitment question produces several plausible futures")
    func commitmentQuestion() {
        let futures = IntentFuturesPlanner.futures(
            scene: replyScene("Can you send the deck before the call?"),
            textBeforeCursor: ""
        )
        let kinds = futures.map(\.kind)
        #expect(kinds.contains(.answer))
        #expect(kinds.contains(.accept))
        #expect(kinds.contains(.commit))
        #expect(futures.count <= IntentFuturesPlanner.maximumFutures)
        #expect(abs(futures.reduce(0) { $0 + $1.weight } - 1) < 0.0001)
    }

    @Test("First completed acceptance word collapses toward accept")
    func yesCollapses() {
        let futures = IntentFuturesPlanner.futures(
            scene: replyScene("Are you still coming tonight?"),
            textBeforeCursor: "Yep "
        )
        #expect(futures.first?.kind == .accept)
    }

    @Test("First completed question word collapses toward clarification")
    func questionCollapses() {
        let futures = IntentFuturesPlanner.futures(
            scene: replyScene("Can you send the latest one?"),
            textBeforeCursor: "Which "
        )
        #expect(futures.first?.kind == .clarify)
        #expect(futures.contains { $0.kind == .question })
    }

    @Test("First completed commitment phrase collapses toward commit")
    func commitCollapses() {
        let futures = IntentFuturesPlanner.futures(
            scene: replyScene("Could you have it by Friday?"),
            textBeforeCursor: "I can "
        )
        #expect(futures.first?.kind == .commit)
    }

    @Test("Non-reply scenes stay out of the way")
    func composingDoesNotInventIntent() {
        let scene = ScreenScene.Scene(mode: .composing, conversationTurns: [], referenceSnippets: [])
        let futures = IntentFuturesPlanner.futures(scene: scene, textBeforeCursor: "I think ")
        #expect(futures == [.init(kind: .continueWriting, weight: 1)])
        #expect(IntentFuturesPlanner.promptHint(for: futures).isEmpty)
    }

    @Test("\"Not a problem\" is not misread as a decline because it starts with \"no\"")
    func notIsNotMisclassifiedAsDecline() {
        let futures = IntentFuturesPlanner.futures(
            scene: replyScene("Sorry I forgot to reply earlier."),
            textBeforeCursor: "Not a problem "
        )
        #expect(!futures.contains { $0.kind == .decline })
    }

    @Test("\"You too\" is not misread as an accept because it starts with \"y\"")
    func youIsNotMisclassifiedAsAccept() {
        let futures = IntentFuturesPlanner.futures(
            scene: replyScene("Thanks for helping me move last weekend."),
            textBeforeCursor: "You too "
        )
        #expect(!futures.contains { $0.kind == .accept })
    }

    @Test("Prompt hint contains labels only")
    func promptHintIsContentFree() {
        let futures = IntentFuturesPlanner.futures(
            scene: replyScene("What do you think about delaying launch?"),
            textBeforeCursor: "I think "
        )
        let hint = IntentFuturesPlanner.promptHint(for: futures)
        #expect(hint.contains("answer:"))
        #expect(!hint.contains("launch"))
        #expect(!hint.contains("delaying"))
    }
}
