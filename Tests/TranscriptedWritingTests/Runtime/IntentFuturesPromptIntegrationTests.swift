import TranscriptedWritingCore
import Testing
@testable import TranscriptedWritingRuntime

@Suite("Intent futures live prompt integration")
struct IntentFuturesPromptIntegrationTests {
    @Test("Hint is inserted only before the live continuation marker")
    func insertsBeforeLastMarker() {
        let scene = ScreenScene.Scene(
            mode: .replying,
            conversationTurns: [.init(speaker: .other, text: "Can you send it tonight?")],
            referenceSnippets: []
        )
        let recipe = RawContinuationPrompt(textBeforeCursor: "I can ", register: .email, scene: scene)
        let prompt = LlamaCompletionEngine.promptByAddingIntentFutures(
            to: recipe.prompt,
            register: .email,
            scene: scene,
            textBeforeCursor: "I can "
        )

        let occurrences = prompt.components(separatedBy: "Likely response directions:").count - 1
        #expect(occurrences == 1)
        #expect(prompt.contains("Text: I can\nLikely response directions:"))
        #expect(prompt.hasSuffix("Continuation:"))
    }

    @Test("No reply scene preserves the original prompt byte for byte")
    func noScenePreservesPrompt() {
        let recipe = RawContinuationPrompt(textBeforeCursor: "hello there ", register: .prose, scene: nil)
        let prompt = LlamaCompletionEngine.promptByAddingIntentFutures(
            to: recipe.prompt,
            register: .prose,
            scene: nil,
            textBeforeCursor: "hello there "
        )
        #expect(prompt == recipe.prompt)
    }

    @Test("The chat register never receives the hint")
    func chatRegisterSkipsHint() {
        let scene = ScreenScene.Scene(
            mode: .replying,
            conversationTurns: [.init(speaker: .other, text: "Can you send it tonight?")],
            referenceSnippets: []
        )
        let recipe = RawContinuationPrompt(textBeforeCursor: "I can ", register: .chat, scene: scene)
        let prompt = LlamaCompletionEngine.promptByAddingIntentFutures(
            to: recipe.prompt,
            register: .chat,
            scene: scene,
            textBeforeCursor: "I can "
        )
        #expect(prompt == recipe.prompt)
        #expect(!prompt.contains("Likely response directions:"))
    }
}
