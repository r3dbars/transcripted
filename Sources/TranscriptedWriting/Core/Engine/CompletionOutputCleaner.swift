import Foundation

public enum CompletionCleanRejectionReason: String, Sendable {
    case unsafeHiddenOrControlCharacter
    case emptyOutput
    case noSuggestionSentinel
    case promptInstructionEcho
    case emptyAfterPrefixTrimming
    case replaysContext
    case repeatsItself
}

public enum CompletionCleanResult: Sendable {
    case accepted(CompletionSuggestion)
    case rejected(CompletionCleanRejectionReason)

    public var suggestion: CompletionSuggestion? {
        guard case let .accepted(suggestion) = self else { return nil }
        return suggestion
    }

    public var rejectionReason: CompletionCleanRejectionReason? {
        guard case let .rejected(reason) = self else { return nil }
        return reason
    }
}

/// A cleaning result plus whether more raw output could still change it.
///
/// The display cap has a prefix property: once the continuation already
/// holds more words than the visible word cap, or more characters than the
/// character cap, every later token lands past the cut and cannot move the
/// visible text. A streaming caller can stop paying for those tokens.
/// `visibleTextIsSettled` is also true for the two rejections that later
/// tokens cannot undo: an unsafe scalar anywhere in the output, and a
/// context replay, which only ever gains n-grams as the output grows.
public struct CompletionCleanOutcome: Sendable {
    public let result: CompletionCleanResult
    public let visibleTextIsSettled: Bool

    public init(result: CompletionCleanResult, visibleTextIsSettled: Bool) {
        self.result = result
        self.visibleTextIsSettled = visibleTextIsSettled
    }
}

/// Lab-selectable cleanup behavior. Production call sites use `.production`;
/// experimental callers can ablate individual judgment rules without
/// weakening unsafe-character rejection or changing the shipping defaults.
public struct CompletionCleaningPolicy: Equatable, Sendable {
    public var rejectsPromptInstructionEcho: Bool
    public var rejectsContextReplay: Bool
    public var trimsSelfRepetition: Bool
    public var repairsDanglingTail: Bool

    public static let production = CompletionCleaningPolicy()

    public init(
        rejectsPromptInstructionEcho: Bool = true,
        rejectsContextReplay: Bool = true,
        trimsSelfRepetition: Bool = true,
        repairsDanglingTail: Bool = true
    ) {
        self.rejectsPromptInstructionEcho = rejectsPromptInstructionEcho
        self.rejectsContextReplay = rejectsContextReplay
        self.trimsSelfRepetition = trimsSelfRepetition
        self.repairsDanglingTail = repairsDanglingTail
    }
}

public struct CompletionOutputCleaner: Sendable {
    private static let noSuggestion = "<no_suggestion>"
    private static let wrappers = CharacterSet(charactersIn: "\"'`")
    private static let unsafeScalars: Set<Unicode.Scalar> = [
        "\u{200B}", "\u{200C}", "\u{200D}", "\u{2060}", "\u{FEFF}",
    ]
    private static let instructionPrefixes = [
        "the following are real chat messages being written by their authors",
        "the following are real emails being written by their authors",
        "the following are real documents being written by their authors",
        "system:", "assistant:",
        "thinking process", "analyze the request", "okay, let's see", "okay, the user",
    ]
    private static let refusalMarkers = [
        "i cannot assist", "i can't assist", "cannot help with that",
    ]

    private let maxVisibleWords: Int
    private let maxVisibleCharacters: Int?
    private let policy: CompletionCleaningPolicy

    public init(
        maxVisibleWords: Int = CompletionSuggestion.defaultMaxVisibleWords,
        maxVisibleCharacters: Int? = nil,
        policy: CompletionCleaningPolicy = .production
    ) {
        self.maxVisibleWords = CompletionSuggestion.clampedVisibleWords(maxVisibleWords)
        self.maxVisibleCharacters = maxVisibleCharacters.map { max(1, $0) }
        self.policy = policy
    }

    public func cleanWithReason(
        _ rawOutput: String,
        after textBeforeCursor: String?
    ) -> CompletionCleanResult {
        clean(rawOutput, after: textBeforeCursor).result
    }

    /// The prepared-context form of `cleanWithReason`.
    public func cleanWithReason(
        _ rawOutput: String,
        in context: PreparedTypedContext
    ) -> CompletionCleanResult {
        clean(rawOutput, in: context).result
    }

    /// `cleanWithReason` plus the settlement bit a streaming caller needs to
    /// decide whether the helper should keep decoding. See
    /// `CompletionCleanOutcome`.
    ///
    /// Convenience entry point: it reduces the context and calls the
    /// prepared form below. A caller that cleans the same context more than
    /// once — every streaming caller — should build a `PreparedTypedContext`
    /// once and use that form instead, so the context is tokenized once per
    /// request rather than once per partial.
    public func clean(
        _ rawOutput: String,
        after textBeforeCursor: String?
    ) -> CompletionCleanOutcome {
        clean(rawOutput, in: PreparedTypedContext(textBeforeCursor: textBeforeCursor))
    }

    /// The cleaning pass itself, against a context reduced once per request.
    public func clean(
        _ rawOutput: String,
        in context: PreparedTypedContext
    ) -> CompletionCleanOutcome {
        guard !containsUnsafeCharacter(rawOutput) else {
            return CompletionCleanOutcome(
                result: .rejected(.unsafeHiddenOrControlCharacter),
                visibleTextIsSettled: true
            )
        }

        var candidate = rawOutput
            .replacingOccurrences(of: #"(?is)<think>.*?</think>"#, with: "", options: .regularExpression)
            .replacingOccurrences(of: #"(?i)</?think>"#, with: "", options: .regularExpression)
            .components(separatedBy: .newlines)[0]
        candidate = unwrapped(candidate)

        guard !candidate.isEmpty else { return .unsettled(.rejected(.emptyOutput)) }
        guard !isNoSuggestion(candidate) else { return .unsettled(.rejected(.noSuggestionSentinel)) }

        candidate = unwrapped(strippingAnswerLabel(from: candidate))
        guard !candidate.isEmpty else { return .unsettled(.rejected(.emptyOutput)) }
        guard !isNoSuggestion(candidate) else { return .unsettled(.rejected(.noSuggestionSentinel)) }
        if policy.rejectsPromptInstructionEcho, isInstructionLeak(candidate) {
            return .unsettled(.rejected(.promptInstructionEcho))
        }

        var continuation = candidate.first?.isWhitespace == true ? candidate : " " + candidate
        // `trimTypedPrefix` (and its `stripLeadingWordEcho` branch) and
        // `replaysContext` below both want the typed context's normalized
        // words, and each used to derive them independently — over the whole
        // bounded context, on every streamed word of every request. They now
        // read one `PreparedTypedContext` built once per request.
        if context.isPresent {
            continuation = trimTypedPrefix(continuation, in: context)
        }
        guard !continuation.trimmingCharacters(in: .whitespaces).isEmpty else {
            return .unsettled(.rejected(.emptyAfterPrefixTrimming))
        }
        if policy.rejectsContextReplay,
           context.isPresent,
           replaysContext(continuation, contextWords: context.words) {
            return CompletionCleanOutcome(
                result: .rejected(.replaysContext),
                visibleTextIsSettled: true
            )
        }

        if policy.trimsSelfRepetition {
            let deduped = trimmingSelfRepetition(continuation)
            if deduped != continuation {
                guard deduped.contains(where: { $0.isLetter || $0.isNumber }) else {
                    return .unsettled(.rejected(.repeatsItself))
                }
                continuation = deduped
            }
        }

        return CompletionCleanOutcome(
            result: .accepted(CompletionSuggestion(
                text: continuation,
                maxVisibleWords: maxVisibleWords,
                maxVisibleCharacters: maxVisibleCharacters,
                repairsDanglingTail: policy.repairsDanglingTail
            )),
            visibleTextIsSettled: capHasBitten(continuation)
        )
    }

    /// True once the display cap has cut `continuation` somewhere later
    /// tokens cannot reach: strictly more words than the word cap, or a
    /// word-capped text strictly longer than the character cap. Both are
    /// exactly the predicates `CompletionSuggestion.cappedText` applies, so a
    /// caller that stops decoding here sees the same visible text the final
    /// cleaning pass would have produced from a longer output. Equality is
    /// deliberately not enough: at exactly the cap the last word may still be
    /// growing, and at exactly the character limit the next character decides
    /// whether the cut lands on a whitespace boundary.
    private func capHasBitten(_ continuation: String) -> Bool {
        if CompletionContextWords.wordRanges(in: continuation).count > maxVisibleWords { return true }
        let characterLimit = maxVisibleCharacters
            ?? CompletionSuggestion.defaultMaxVisibleCharacters(forVisibleWords: maxVisibleWords)
        let wordCapped = CompletionSuggestion.acceptedPrefix(in: continuation, wordLimit: maxVisibleWords)
        return wordCapped.count > characterLimit
    }

    private func unwrapped(_ text: String) -> String {
        text.trimmingCharacters(in: .whitespacesAndNewlines).trimmingCharacters(in: Self.wrappers)
    }

    private func isNoSuggestion(_ text: String) -> Bool {
        unwrapped(text).lowercased() == Self.noSuggestion
    }

    private func strippingAnswerLabel(from text: String) -> String {
        text.replacingOccurrences(
            of: #"^(?:candidate\s+\d+\s*[\).:-]\s*|(?:next words?|continuation|completion|suggestion|suffix)\s*:\s*)"#,
            with: "",
            options: [.regularExpression, .caseInsensitive]
        )
    }

    private func isInstructionLeak(_ text: String) -> Bool {
        let normalized = text.lowercased().trimmingCharacters(in: .whitespacesAndNewlines)
        if normalized.range(
            of: #"^(?:(?:i(?:['’]m| am) sorry,\s*(?:but\s+)?)as (?:an ai(?: assistant| chatbot| language model)?|a language model)\b|as (?:an ai(?: assistant| chatbot| language model)?|a language model)\b[,\s]+(?:i|my)\b|i(?:['’]m| am) (?:an ai(?: assistant| chatbot| language model)?|a language model)\b)"#,
            options: .regularExpression
        ) != nil {
            return true
        }
        if normalized.range(
            of: #"^(?:candidate\s+\d+|next(?:\s+\d+-\d+)? words?|continuation|completion|suggestion|suffix)\s*:?(?:,\s*or\s*<no_suggestion>)?$"#,
            options: .regularExpression
        ) != nil {
            return true
        }
        return Self.instructionPrefixes.contains(where: normalized.hasPrefix)
            || Self.refusalMarkers.contains(where: normalized.contains)
    }

    private func containsUnsafeCharacter(_ text: String) -> Bool {
        text.unicodeScalars.contains { scalar in
            Self.unsafeScalars.contains(scalar)
                || (scalar != "\n" && scalar != "\r" && CharacterSet.controlCharacters.contains(scalar))
        }
    }

    private func trimTypedPrefix(
        _ suggestion: String, in context: PreparedTypedContext
    ) -> String {
        let contextWords = context.words
        if context.endsWithWhitespace {
            let dropped = String(suggestion.drop(while: \.isWhitespace))
            // The word-boundary-only echo guard: when the cursor sits right
            // after whitespace, the last typed word is complete, so unlike
            // the branch below there is no partial-word case to consider —
            // only "does the suggestion open by re-typing the tail of what's
            // already on screen." Screen-context prompts (Conversation/
            // Reference blocks ahead of `Text:`) make this common: a model
            // echoing its own just-read context back is exactly the
            // observed live bug (typed "Sure, I will " -> ghost "I will try
            // to get back to you", a 2-word echo `replaysContext` never sees
            // because that check only fires on 3+-word overlaps). Any
            // leading run of fully-repeated words — down to a single word —
            // gets stripped here, before `replaysContext`'s coarser check
            // ever runs.
            return stripLeadingWordEcho(dropped, contextWords: contextWords)
        }
        // A punctuation-only trailing token has no fragment. Treating its
        // normalized empty string as a prefix used to drop the first character.
        guard context.endsWithLetter else { return suggestion }

        let suggestionRanges = CompletionContextWords.wordRanges(in: suggestion)
        let suggestionWords = suggestionRanges.map { CompletionContextWords.normalized(String(suggestion[$0])) }
        guard !contextWords.isEmpty, !suggestionWords.isEmpty else { return suggestion }

        for count in stride(from: min(contextWords.count, suggestionWords.count), through: 1, by: -1) {
            let typed = Array(contextWords.suffix(count))
            let offered = Array(suggestionWords.prefix(count))
            if typed == offered {
                guard count < suggestionRanges.count else { return "" }
                return " " + suggestion[suggestionRanges[count].lowerBound...]
            }

            guard typed.dropLast() == offered.dropLast(),
                  let typedLast = typed.last,
                  let offeredLast = offered.last,
                  !typedLast.isEmpty,
                  offeredLast.hasPrefix(typedLast),
                  typedLast.count < offeredLast.count else { continue }
            let range = suggestionRanges[count - 1]
            guard let start = suggestion.index(
                range.lowerBound,
                offsetBy: typedLast.count,
                limitedBy: range.upperBound
            ) else { continue }
            return String(suggestion[start...])
        }
        return suggestion
    }

    /// Strips a leading run of whole words in `suggestion` that exactly
    /// repeats the tail of the typed context, longest match first (so "I will"
    /// trims as one unit rather than leaving a dangling "will"). Only exact,
    /// case/punctuation-normalized whole-word matches count — this runs only
    /// when the typed context ends in whitespace, so there is no partial last
    /// word to reason about the way `trimTypedPrefix`'s other branch does.
    private func stripLeadingWordEcho(_ suggestion: String, contextWords: [String]) -> String {
        let suggestionRanges = CompletionContextWords.wordRanges(in: suggestion)
        let suggestionWords = suggestionRanges.map { CompletionContextWords.normalized(String(suggestion[$0])) }
        guard !contextWords.isEmpty, !suggestionWords.isEmpty else { return suggestion }

        for count in stride(from: min(contextWords.count, suggestionWords.count), through: 1, by: -1) {
            let typed = Array(contextWords.suffix(count))
            let offered = Array(suggestionWords.prefix(count))
            guard typed == offered else { continue }
            guard count < suggestionRanges.count else { return "" }
            return String(suggestion[suggestionRanges[count].lowerBound...])
        }
        return suggestion
    }

    private func replaysContext(_ suggestion: String, contextWords typed: [String]) -> Bool {
        let offered = CompletionContextWords.normalizedWords(in: suggestion)
        guard offered.count >= 3, typed.count >= 3 else { return false }

        for size in stride(from: min(4, offered.count), through: 3, by: -1) {
            if contains(Array(offered.prefix(size)), in: typed) { return true }
        }
        guard offered.count >= 4 else { return false }
        return offered.indices.dropLast(3).contains { index in
            contains(Array(offered[index..<offered.index(index, offsetBy: 4)]), in: typed)
        }
    }

    /// Live dogfood regression (build 2705, rapid-fire chat): typed
    /// "Hey I am", ghost offered " here, I am here." — the suggestion's own
    /// tail re-states its opening clause. `replaysContext` only compares
    /// against the TYPED context, so a model looping on its own words sails
    /// through. This trims the suggestion at the point where it starts
    /// repeating itself: a 3-word run repeated back-to-back ("let me know
    /// let me know"), a clause identical to an earlier clause ("sounds
    /// good, sounds good"), or a final clause that ENDS by re-stating a
    /// whole earlier clause (the observed "here, … here." loop). Three
    /// deliberate false-positive guards, all from independent review:
    /// the run rule requires ADJACENT repetition, so parallel rhetoric
    /// ("the more you practice, the more you improve") survives; the
    /// end-anchored rule stands down when the echo sits behind a negator
    /// the earlier clause didn't have ("done. It is not done"), where
    /// trimming would ship the OPPOSITE of what the model said; and the
    /// end-anchored rule ALSO stands down when the words leading into the
    /// echo carry new content, not just function words -- code review
    /// caught two false positives this closes: "Ready? Get ready" was
    /// trimmed to "Ready?" (deleting the action word "Get"), and "it is
    /// ready, or at least they say it is ready" lost its whole qualifying
    /// clause. Both echo a single earlier clause, but the words in front of
    /// the echo ("Get" / "or at least they say") are new information, not a
    /// degenerate loop -- unlike the "here, I am here." case, where "I am"
    /// ahead of the echoed "here" is pure connective tissue.
    private func trimmingSelfRepetition(_ suggestion: String) -> String {
        let clauseBreaks: Set<Character> = [",", ".", ";", ":", "!", "?"]
        var wordStarts: [String.Index] = []
        var words: [String] = []
        var endsClause: [Bool] = []
        for range in CompletionContextWords.wordRanges(in: suggestion) {
            let token = String(suggestion[range])
            let word = CompletionContextWords.normalized(token)
            let breaksHere = token.last.map(clauseBreaks.contains) ?? false
            if !word.isEmpty {
                wordStarts.append(range.lowerBound)
                words.append(word)
                endsClause.append(breaksHere)
            } else if breaksHere, !endsClause.isEmpty {
                // A detached punctuation token still closes the clause of
                // the word before it.
                endsClause[endsClause.count - 1] = true
            }
        }
        guard words.count >= 2 else { return suggestion }

        var cut = words.count

        if words.count >= 6 {
            for start in 3...(words.count - 3) where Array(words[start - 3..<start]) == Array(words[start..<start + 3]) {
                cut = start
                break
            }
        }

        var clauses: [[Int]] = [[]]
        for index in words.indices {
            clauses[clauses.count - 1].append(index)
            if endsClause[index], index < words.count - 1 {
                clauses.append([])
            }
        }
        for j in 1..<clauses.count {
            let clause = clauses[j].map { words[$0] }
            let earlier = clauses[0..<j].map { indices in indices.map { words[$0] } }
            let exactRepeat = earlier.contains { $0 == clause }
            let finalClauseEndsOnEarlierClause = j == clauses.count - 1 && earlier.contains { earlierClause in
                guard clause.count > earlierClause.count,
                      Array(clause.suffix(earlierClause.count)) == earlierClause else { return false }
                let beforeEcho = clause.prefix(clause.count - earlierClause.count)
                // Only a genuinely substantive earlier clause (one with real
                // content of its own, not just a symbol) is worth guarding
                // this way -- a symbol-only "clause" isn't legitimate
                // rhetoric being introduced, it's still a degenerate loop.
                if earlierClause.contains(where: isContentWord), beforeEcho.contains(where: isContentWord) {
                    return false
                }
                return !beforeEcho.contains(where: isNegator) || earlierClause.contains(where: isNegator)
            }
            guard exactRepeat || finalClauseEndsOnEarlierClause else { continue }
            cut = min(cut, clauses[j][0])
            break
        }

        guard cut < words.count else { return suggestion }
        var trimmed = String(suggestion[..<wordStarts[cut]])
        while let last = trimmed.last, last.isWhitespace || last == "," || last == ";" || last == ":" {
            trimmed.removeLast()
        }
        return trimmed
    }

    private static let negators: Set<String> = ["not", "no", "never", "none", "cannot", "nor"]

    private func isNegator(_ word: String) -> Bool {
        Self.negators.contains(word) || word.hasSuffix("n't") || word.hasSuffix("n\u{2019}t")
    }

    /// Function words only: pronouns, "to be"/modal auxiliaries, articles,
    /// and the most common conjunctions/prepositions. Anything NOT in this
    /// list -- verbs like "get", nouns/adjectives like "least" -- counts as
    /// content the final clause is introducing, not just connective tissue
    /// stitching it to the echoed clause. Deliberately small and generic
    /// (not this codebase's message-content stopword list): it exists only
    /// to tell "the ready. It is ready" (pure restatement) apart from
    /// "Ready? Get ready" (a new instruction that happens to end on an
    /// earlier word).
    private static let functionWords: Set<String> = [
        "i", "you", "he", "she", "it", "we", "they",
        "me", "him", "her", "us", "them",
        "my", "your", "his", "its", "our", "their",
        "this", "that", "these", "those",
        "am", "is", "are", "was", "were", "be", "been", "being",
        "do", "does", "did", "will", "would", "shall", "should", "can", "could", "may", "might", "must",
        "a", "an", "the",
        "and", "or", "but", "nor", "so", "yet",
        "to", "of", "in", "on", "at", "by", "from", "with", "as", "for",
    ]

    private func isContentWord(_ word: String) -> Bool {
        word.contains(where: \.isLetter) && !Self.functionWords.contains(word) && !isNegator(word)
    }

    private func contains(_ needle: [String], in words: [String]) -> Bool {
        guard words.count >= needle.count else { return false }
        return words.indices.dropLast(needle.count - 1).contains { index in
            Array(words[index..<words.index(index, offsetBy: needle.count)]) == needle
        }
    }

}

private extension CompletionCleanOutcome {
    /// A result later tokens could still change.
    static func unsettled(_ result: CompletionCleanResult) -> CompletionCleanOutcome {
        CompletionCleanOutcome(result: result, visibleTextIsSettled: false)
    }
}
