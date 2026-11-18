import Foundation

/// The model calls the titles job needs. Production is a llama-server child;
/// tests use a fake.
protocol MeetingTitlesEngine: AnyObject, Sendable {
    /// Tokens the model's own tokenizer counts in `text`.
    func countTokens(_ text: String) async throws -> Int
    /// POSTs a `/v1/chat/completions` JSON body and returns the reply text.
    func chat(body: Data) async throws -> String
}

/// Starts the engine when there is work and stops it when there isn't.
protocol MeetingTitlesEngineHost: AnyObject, Sendable {
    func start() async throws -> any MeetingTitlesEngine
    func stop() async
    /// Ends a helper an earlier, crashed run of the app left behind.
    func reapOrphaned() async
}

extension MeetingTitlesEngineHost {
    func reapOrphaned() async {}
}

enum MeetingTitlesEngineError: Error, Equatable {
    case helperMissing
    case bundleSealInvalid
    case launchFailed
    case healthTimeout
    case notRunning
    case requestFailed
}

/// One meeting through the model: transcript in, guarded label out.
enum MeetingTitlesLabeler {
    enum Outcome: Equatable {
        case labeled(MeetingTitlesLabel, droppedTurns: Int)
        /// The reply wasn't `{title, line, summary}` or every field was
        /// guarded out. Nothing is written.
        case unusableReply
    }

    /// The turns worth sending, or nil when the meeting is too short to label
    /// (no model call happens then).
    static func labelableTurns(fromMeetingMarkdown markdown: String) -> [MeetingTitlesTurn]? {
        let turns = MeetingTitlesTranscript.turns(fromMeetingMarkdown: markdown)
        return MeetingTitlesTranscript.wordCount(turns) >= MeetingTitlesTranscript.minimumWords ? turns : nil
    }

    static func label(
        _ turns: [MeetingTitlesTurn],
        engine: any MeetingTitlesEngine,
        budget: Int = MeetingTitlesFit.promptTokenBudget
    ) async throws -> Outcome {
        let systemTokens = try await engine.countTokens(MeetingTitlesPrompt.system)
        let fitted = try await MeetingTitlesFit.fit(
            turns,
            systemTokens: systemTokens,
            budget: budget,
            countTokens: { try await engine.countTokens($0) }
        )
        let body = MeetingTitlesPrompt.chatRequestBody(transcript: fitted.transcript)
        let reply = try await engine.chat(body: body)
        guard let label = MeetingTitlesGuards.label(fromModelReply: reply), !label.isEmpty else {
            return .unusableReply
        }
        return .labeled(label, droppedTurns: fitted.droppedTurns)
    }
}
