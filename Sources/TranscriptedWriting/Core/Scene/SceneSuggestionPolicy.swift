import Foundation

/// Deterministic silence gates for scene shapes where a small completion
/// model should not be asked to decide what to say. Screen text is untrusted
/// data: quoting it in the prompt prevents structural prompt splicing, but it
/// does not guarantee that the model will ignore an instruction written inside
/// that data. These checks run before inference and therefore cannot be
/// bypassed by sampling configuration or model behavior.
public enum SceneSuggestionPolicy {
    public enum SuppressionReason: String, CaseIterable, Equatable, Sendable {
        case promptInjection = "prompt-injection-scene"
        case noIncomingTurn = "no-incoming-turn"
        case resolvedConversation = "resolved-conversation"
        case ambiguousChoice = "ambiguous-choice"
        case nonActionableScene = "non-actionable-scene"
        case completeSentence = "complete-sentence-scene"
        case multipleQuestions = "multiple-questions-scene"
        case ambiguousReference = "ambiguous-reference-scene"
    }

    /// Gate selection. Production ships the five settled detectors only; the
    /// extended ordinary-silence detectors are development-only measurement
    /// machinery until a registered display-policy experiment promotes them.
    public struct Options: Equatable, Sendable {
        public var extendedOrdinarySilenceGate: Bool
        /// The non-actionable gate's escape hatch asks whether the writer
        /// has begun a reply ("okay", "thanks", "I will"). Production reads
        /// that cue off the head of the whole bounded field text, which in
        /// a long composer, a document, or a mail reply with quoted text is
        /// never a reply cue, so the gate silences replies the writer has
        /// plainly started. With this on, the cue is read from the sentence
        /// the writer is in. Owner-directed for the 9B preview (2026-09-01);
        /// production stays as measured until a display-policy campaign
        /// promotes it.
        public var replyCueAnchoredToCurrentSentence: Bool

        public init(
            extendedOrdinarySilenceGate: Bool = false,
            replyCueAnchoredToCurrentSentence: Bool = false
        ) {
            self.extendedOrdinarySilenceGate = extendedOrdinarySilenceGate
            self.replyCueAnchoredToCurrentSentence = replyCueAnchoredToCurrentSentence
        }

        public static let production = Options()
    }

    public static func suppressionReason(
        scene: ScreenScene.Scene?,
        textBeforeCursor: String? = nil,
        options: Options = .production
    ) -> SuppressionReason? {
        guard let scene else { return nil }
        let visibleText = scene.conversationTurns.map(\.text) + scene.referenceSnippets
        if visibleText.contains(where: containsInstructionOverride) {
            return .promptInjection
        }

        guard scene.mode == .replying else { return nil }
        let turns = scene.conversationTurns
        let incomingIndices = turns.indices.filter {
            turns[$0].speaker != .selfSpeaker
        }
        guard let newestIncomingIndex = incomingIndices.last else {
            return turns.isEmpty ? nil : .noIncomingTurn
        }
        let hasEarlierSelfTurn = turns[..<newestIncomingIndex].contains {
            $0.speaker == .selfSpeaker
        }
        let incoming = turns[newestIncomingIndex].text
        if hasEarlierSelfTurn, isShortClosure(incoming) {
            return .resolvedConversation
        }
        if !hasEarlierSelfTurn, isAmbiguousChoice(incoming) {
            return .ambiguousChoice
        }
        if !hasEarlierSelfTurn,
           let textBeforeCursor,
           isNonActionableDeclarative(incoming),
           !writerHasStartedReply(textBeforeCursor, options: options) {
            return .nonActionableScene
        }
        guard options.extendedOrdinarySilenceGate else { return nil }
        if isFinishedSentence(textBeforeCursor), isSettledStatement(incoming) {
            return .completeSentence
        }
        if interrogativeClauseCount(incoming) > 1,
           !hasQuestionSelectionCue(textBeforeCursor) {
            return .multipleQuestions
        }
        if isReferentiallyAmbiguous(incoming) {
            return .ambiguousReference
        }
        return nil
    }

    private static func containsInstructionOverride(_ text: String) -> Bool {
        let range = NSRange(text.startIndex..., in: text)
        return instructionPatterns.contains {
            $0.firstMatch(in: text, range: range) != nil
        }
    }

    private static func isShortClosure(_ text: String) -> Bool {
        guard !text.contains("?") else { return false }
        let words = normalizedWords(text)
        guard !words.isEmpty, words.count <= 6 else { return false }
        let phrase = words.joined(separator: " ")
        return closurePrefixes.contains { phrase == $0 || phrase.hasPrefix($0 + " ") }
    }

    private static func isAmbiguousChoice(_ text: String) -> Bool {
        guard text.contains("?") else { return false }
        let words = normalizedWords(text)
        guard words.contains("or") else { return false }
        return !Set(words).isDisjoint(with: preferenceWords)
    }

    private static func normalizedWords(_ text: String) -> [String] {
        text.lowercased().split { !$0.isLetter && !$0.isNumber }.map(String.init)
    }

    private static func isNonActionableDeclarative(_ text: String) -> Bool {
        guard !text.contains("?") else { return false }
        let words = Set(normalizedWords(text))
        return words.isDisjoint(with: requestWords)
    }

    private static func hasReplyCue(_ text: String) -> Bool {
        let phrase = normalizedWords(text).joined(separator: " ")
        return replyPrefixes.contains { phrase == $0 || phrase.hasPrefix($0 + " ") }
    }

    /// Once the paragraph the writer is in carries this many words they
    /// have plainly started a reply, cue word or not. The gate exists to
    /// keep a statement that asked nothing from drawing an opening ghost; it
    /// was never meant to silence a reply already under way. The paragraph,
    /// not the sentence: a chained accept in a chat composer routinely ends
    /// a sentence, and the next request must not be judged on an empty one.
    static let startedReplyMinimumWords = 3

    /// The non-actionable gate's escape hatch. Production reads a reply cue
    /// off the head of the whole field. The anchored option reads it off the
    /// current sentence and also stands down once the current paragraph is
    /// under way (`startedReplyMinimumWords`).
    private static func writerHasStartedReply(_ text: String, options: Options) -> Bool {
        guard options.replyCueAnchoredToCurrentSentence else { return hasReplyCue(text) }
        return hasReplyCue(currentSentence(of: text))
            || normalizedWords(currentParagraph(of: text)).count >= startedReplyMinimumWords
    }

    /// The text after the last line break: the paragraph the writer is in.
    static func currentParagraph(of text: String) -> String {
        guard let index = text.lastIndex(where: \.isNewline) else { return text }
        return String(text[text.index(after: index)...])
    }

    /// The text after the last sentence terminator or line break: the
    /// sentence the writer is in, which is where a reply cue actually sits.
    static func currentSentence(of text: String) -> String {
        let boundaries: Set<Character> = [".", "!", "?", "\n"]
        guard let index = text.lastIndex(where: boundaries.contains) else { return text }
        return String(text[text.index(after: index)...])
    }

    // MARK: - Extended ordinary-silence detectors (development-only)

    /// The writer already ended a sentence, so there is nothing to finish.
    private static func isFinishedSentence(_ text: String?) -> Bool {
        guard let text else { return false }
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let last = trimmed.last, terminators.contains(last) else { return false }
        return normalizedWords(trimmed).count >= 2
    }

    /// A finished incoming statement that asks the writer for nothing.
    private static func isSettledStatement(_ text: String) -> Bool {
        guard !text.contains("?") else { return false }
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let last = trimmed.last, last == "." || last == "!" else { return false }
        return !hasDirectRequestCue(trimmed)
    }

    /// Counts the interrogative clauses inside the incoming turn's questions.
    /// A comma-joined "should we X, and should Y" counts as two.
    private static func interrogativeClauseCount(_ text: String) -> Int {
        sentences(in: text).filter(\.isQuestion).reduce(0) { total, sentence in
            total + sentence.text.split(separator: ",").reduce(0) { count, clause in
                var words = normalizedWords(String(clause))
                while let first = words.first, clauseConnectors.contains(first) {
                    words.removeFirst()
                }
                guard let lead = words.first, interrogativeLeads.contains(lead) else { return count }
                return count + 1
            }
        }
    }

    /// The writer signalled which of several questions they are answering.
    private static func hasQuestionSelectionCue(_ text: String?) -> Bool {
        guard let text else { return false }
        let phrase = normalizedWords(text).joined(separator: " ")
        return questionSelectionPhrases.contains { phrase.contains($0) }
    }

    /// A request whose object is a bare pronoun while the same turn offers
    /// more than one candidate referent.
    private static func isReferentiallyAmbiguous(_ text: String) -> Bool {
        let parts = sentences(in: text)
        guard let request = parts.last(where: { $0.isQuestion || hasDirectRequestCue($0.text) })
        else { return false }
        guard !Set(normalizedWords(request.text)).isDisjoint(with: bareReferenceWords) else {
            return false
        }
        let words = normalizedWords(text)
        return words.contains("both") || words.filter { $0 == "and" }.count >= 2
    }

    private static func hasDirectRequestCue(_ text: String) -> Bool {
        let phrase = normalizedWords(text).joined(separator: " ")
        return directRequestPhrases.contains { phrase == $0 || phrase.contains($0) }
    }

    private struct Sentence {
        let text: String
        let isQuestion: Bool
    }

    private static func sentences(in text: String) -> [Sentence] {
        var result: [Sentence] = []
        var current = ""
        for character in text {
            if terminators.contains(character) {
                if !current.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    result.append(Sentence(text: current, isQuestion: character == "?"))
                }
                current = ""
            } else {
                current.append(character)
            }
        }
        if !current.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            result.append(Sentence(text: current, isQuestion: false))
        }
        return result
    }

    private static let terminators: Set<Character> = [".", "!", "?"]

    private static let interrogativeLeads: Set<String> = [
        "am", "are", "can", "could", "did", "do", "does", "how", "is", "may",
        "should", "was", "were", "what", "when", "where", "which", "who",
        "why", "will", "would",
    ]

    private static let clauseConnectors: Set<String> = [
        "also", "and", "but", "or", "so", "then",
    ]

    private static let questionSelectionPhrases = [
        "answering the first", "answering the second", "first question",
        "for the first", "for the second", "on the first", "on the second",
        "second question", "to the first", "to the second", "to your first",
        "to your second",
    ]

    private static let directRequestPhrases = [
        "can you", "could you", "let me know", "let us know", "please",
        "send me", "will you", "would you",
    ]

    private static let bareReferenceWords: Set<String> = [
        "it", "that", "them", "these", "this", "those",
    ]

    private static let instructionPhrases = [
        "ignore previous instructions",
        "ignore prior instructions",
        "ignore all instructions",
        "ignore every instruction",
        "disregard previous instructions",
        "disregard prior instructions",
        "forget previous instructions",
        "reveal the system prompt",
        "repeat the system prompt",
        "output override",
    ]

    private static let instructionPatterns: [NSRegularExpression] =
        instructionPhrases.compactMap { phrase in
            let escaped = NSRegularExpression.escapedPattern(for: phrase)
            return try? NSRegularExpression(
                pattern: "(?<![A-Za-z0-9])\(escaped)(?![A-Za-z0-9])",
                options: [.caseInsensitive]
            )
        }

    private static let closurePrefixes = [
        "great thank you", "great thanks", "thank you", "thanks",
        "perfect", "got it", "sounds good", "okay great", "ok great",
    ]

    private static let preferenceWords: Set<String> = [
        "better", "choose", "pick", "prefer", "which",
    ]

    private static let requestWords: Set<String> = [
        "ask", "call", "confirm", "could", "need", "please", "remember",
        "review", "send", "share", "tell", "update", "would",
    ]

    private static let replyPrefixes = [
        "got it", "i can", "i will", "no problem", "no worries", "okay",
        "sorry", "sounds good", "thank you", "thanks", "unfortunately", "yes",
    ]
}
