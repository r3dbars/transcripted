import Testing
@testable import TranscriptedWritingCore

@Suite("Intent prompt hint")
struct IntentPromptHintTests {
    @Test("Reply scenes emit a fixed-vocabulary hint")
    func replyHint() {
        let scene = ScreenScene.Scene(
            mode: .replying,
            conversationTurns: [.init(speaker: .other, text: "Can you send it tonight?")],
            referenceSnippets: []
        )
        let block = IntentPromptHint.block(scene: scene, textBeforeCursor: "I can")
        #expect(block.hasPrefix("Likely response directions:"))
        #expect(block.contains("commit:"))
        #expect(!block.contains("tonight"))
    }

    @Test("Ordinary composing adds no prompt noise")
    func composingIsEmpty() {
        let scene = ScreenScene.Scene(mode: .composing, conversationTurns: [], referenceSnippets: [])
        #expect(IntentPromptHint.block(scene: scene, textBeforeCursor: "hello ").isEmpty)
    }
}
