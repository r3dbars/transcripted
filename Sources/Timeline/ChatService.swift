import Foundation

protocol TimelineChatAnswering {
    func answer(prompt: String) async throws -> String
}

struct TimelineChatDraft {
    var prompt: String
    var answer: String
}

struct ChatService {
    private let promptBuilder: ChatPromptBuilder
    private let provider: TimelineChatAnswering

    init(promptBuilder: ChatPromptBuilder = ChatPromptBuilder(), provider: TimelineChatAnswering) {
        self.promptBuilder = promptBuilder
        self.provider = provider
    }

    func answer(context: TimelineChatPromptContext) async throws -> TimelineChatDraft {
        let prompt = try promptBuilder.buildPrompt(context: context)
        let answer = try await provider.answer(prompt: prompt)
        return TimelineChatDraft(prompt: prompt, answer: answer)
    }
}

