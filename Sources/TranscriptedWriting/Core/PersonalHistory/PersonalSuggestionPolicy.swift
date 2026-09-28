import Foundation

public enum PersonalSuggestionSource: String, Equatable, Sendable {
    case base
    case personal
    case agreed
}

/// What a streaming ghost may do while a personal prediction is still racing
/// the generator. The keyboard grows a visible ghost and never rewrites it, so
/// a prefix may only be shown once it is certain the personal layer will not
/// replace the first word.
public enum PersonalStreamDecision: String, Equatable, Sendable {
    /// Not yet decidable — keep the prefix buffered, show nothing.
    case hold
    /// The personal layer cannot displace this ghost; stream normally.
    case stream
    /// A personal replacement won before anything was shown; this request
    /// answers with one final line instead of a stream.
    case finalOnly
}

/// The personal lookup as the streaming gate sees it: still racing, or
/// answered (possibly with nothing). One value, so "resolved with nothing"
/// and "not resolved" cannot both read as `nil`.
public enum PersonalLookupState: Equatable, Sendable {
    case pending
    case resolved(PersonalNextWordPrediction?)
}

public enum PersonalSuggestionPolicy {
    public static let maximumTailWords = 2

    /// The model was trained on `PersonalNextWordShadow`'s letter-run
    /// tokens ("don't" learned as `["don", "t"]`, never `["don't"]`), so
    /// serving must split context the same way — reusing that tokenizer
    /// rather than a second, looser word-splitter keeps the keys serving
    /// looks up in the model the keys the model actually has.
    public static func tailWords(
        fromContext context: String,
        maximumWords: Int = maximumTailWords
    ) -> [String] {
        let tokens = PersonalNextWordShadow.tokenize(context)
        return Array(tokens.suffix(maximumWords))
    }

    public static func candidateSet(
        baseGhost: String,
        personalPrediction: PersonalNextWordPrediction?
    ) -> SuggestionCandidateSet {
        var candidates = [SuggestionCandidate(text: baseGhost, source: .base)]
        if let personalPrediction {
            let confidence = personalPrediction.total > 0
                ? Double(personalPrediction.support) / Double(personalPrediction.total)
                : nil
            candidates.append(SuggestionCandidate(
                text: personalPrediction.word,
                source: .personal,
                confidence: confidence,
                support: personalPrediction.support
            ))
        }
        return SuggestionCandidateSet(candidates)
    }

    /// Production adapter from the new arbiter back to the existing count-only
    /// source vocabulary. The server/UI contract stays stable while selection
    /// becomes a replaceable judge over explicit candidates.
    public static func apply(
        baseGhost: String,
        personalPrediction: PersonalNextWordPrediction?
    ) -> (text: String, source: PersonalSuggestionSource) {
        let set = candidateSet(baseGhost: baseGhost, personalPrediction: personalPrediction)
        let decision = SuggestionArbiter.choose(from: set)
        guard let chosen = decision.candidate else { return ("", .base) }
        switch decision.reason {
        case .expertsAgree:
            return (chosen.text, .agreed)
        case .personalEvidence:
            return (chosen.text, .personal)
        case .baseOnly, .baseFallback, .silence:
            return (chosen.text, .base)
        }
    }

    /// Whether a personal answer could still displace whatever the base
    /// model eventually says. Asked before the base text exists, so it can
    /// only consult the arbiter's evidence bar; a prediction that cannot
    /// clear it will lose to every possible base ghost, which is enough to
    /// release a held stream immediately.
    static func couldReplaceAnyBase(_ prediction: PersonalNextWordPrediction?) -> Bool {
        guard let prediction else { return false }
        let set = candidateSet(baseGhost: "", personalPrediction: prediction)
        guard let personal = set.first(from: .personal) else { return false }
        return SuggestionArbiter.meetsPersonalEvidenceBar(personal)
    }

    /// The streaming gate. `basePrefix` is the longest stable complete-word
    /// prefix the generator has produced so far, or `nil` when it has
    /// produced none yet; `personalLookup` says whether the personal answer
    /// exists yet, and what it was.
    ///
    /// Deciding on the first stable prefix rather than the finished ghost is
    /// sound because the arbiter compares first words only, and a stable
    /// prefix's first word is already the finished ghost's first word — so
    /// "would personal replace this prefix" and "would personal replace the
    /// final ghost" are the same question.
    public static func streamDecision(
        basePrefix: String?,
        personalLookup: PersonalLookupState
    ) -> PersonalStreamDecision {
        // Nothing may be shown while an answer that could replace the first
        // word is still in flight.
        guard case let .resolved(personalPrediction) = personalLookup else { return .hold }
        guard let personalPrediction else { return .stream }
        guard let basePrefix, !basePrefix.isEmpty else {
            return couldReplaceAnyBase(personalPrediction) ? .hold : .stream
        }
        let applied = apply(baseGhost: basePrefix, personalPrediction: personalPrediction)
        return applied.source == .personal ? .finalOnly : .stream
    }

    /// The terminal line's text and source. Identical to `apply` except that
    /// a prefix already on screen is never rewritten: once a partial has
    /// been written, the final honours the base ghost the writer is already
    /// reading, and reports the `base` source it actually served.
    public static func finalSuggestion(
        baseGhost: String,
        personalPrediction: PersonalNextWordPrediction?,
        streamedPrefix: Bool
    ) -> (text: String, source: PersonalSuggestionSource) {
        let applied = apply(baseGhost: baseGhost, personalPrediction: personalPrediction)
        guard streamedPrefix, applied.source == .personal else { return applied }
        return (baseGhost, .base)
    }
}
