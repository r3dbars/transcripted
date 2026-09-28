import Foundation

/// A semantic direction the user may be about to take. These are deliberately
/// broad: Tilde wants a few useful futures, not a brittle taxonomy of every
/// possible speech act.
public struct IntentFuture: Equatable, Sendable {
    public enum Kind: String, Equatable, Sendable, CaseIterable {
        case answer
        case accept
        case decline
        case clarify
        case acknowledge
        case commit
        case question
        case continueWriting = "continue-writing"
    }

    public let kind: Kind
    /// Relative evidence only. Scores are normalized across the returned set,
    /// not advertised as calibrated probabilities.
    public let weight: Double

    public init(kind: Kind, weight: Double) {
        self.kind = kind
        self.weight = min(max(weight, 0), 1)
    }
}

/// Builds a tiny belief state from scene + the text already typed. Pure,
/// deterministic, and framework-free so replay can grade it exactly.
public enum IntentFuturesPlanner {
    public static let maximumFutures = 4
    private static let englishLocale = Locale(identifier: "en_US_POSIX")

    public static func futures(
        scene: ScreenScene.Scene?,
        textBeforeCursor: String,
        maximumFutures: Int = maximumFutures
    ) -> [IntentFuture] {
        guard maximumFutures > 0 else { return [] }

        guard let scene, scene.mode == .replying,
              let latestOther = scene.conversationTurns.last(where: { $0.speaker == .other })?.text
        else {
            return [IntentFuture(kind: .continueWriting, weight: 1)]
        }

        let message = folded(latestOther)
        let typed = folded(currentFragment(in: textBeforeCursor))
        var scores: [IntentFuture.Kind: Double] = [:]

        // Every reply can at least acknowledge or answer. More specific
        // evidence below should dominate these weak priors.
        scores[.acknowledge] = 0.20
        scores[.answer] = 0.20

        if looksLikeQuestion(message) {
            scores[.answer, default: 0] += 0.65
            scores[.clarify, default: 0] += 0.25
        }
        if asksForCommitment(message) {
            scores[.accept, default: 0] += 0.55
            scores[.decline, default: 0] += 0.30
            scores[.commit, default: 0] += 0.45
        }
        if asksForOpinion(message) {
            scores[.answer, default: 0] += 0.45
            scores[.clarify, default: 0] += 0.12
        }

        // The user's first few characters collapse the semantic tree. These
        // are intentionally tiny starter cues, not a language model hidden in
        // a switch statement.
        if hasAnyPrefix(typed, ["yes", "yep", "yeah", "sure", "absolutely", "sounds good"]) {
            scores[.accept, default: 0] += 1.10
            scores[.acknowledge, default: 0] += 0.35
        }
        if hasAnyPrefix(typed, ["nah", "can't", "cannot", "won't", "unfortunately"]) {
            scores[.decline, default: 0] += 1.10
        }
        if hasAnyPrefix(typed, ["what", "which", "when", "where", "who", "why", "how", "do you mean"]) {
            scores[.clarify, default: 0] += 1.00
            scores[.question, default: 0] += 0.65
        }
        if hasAnyPrefix(typed, ["i can", "i'll", "ill", "i will", "let me", "i should be able"]) {
            scores[.commit, default: 0] += 1.05
            scores[.accept, default: 0] += 0.35
        }
        if hasAnyPrefix(typed, ["i think", "honestly", "my take", "probably", "maybe"]) {
            scores[.answer, default: 0] += 0.85
        }

        let ranked = scores
            .filter { $0.value > 0 }
            .sorted {
                if $0.value == $1.value { return $0.key.rawValue < $1.key.rawValue }
                return $0.value > $1.value
            }
            .prefix(maximumFutures)

        let total = ranked.reduce(0.0) { $0 + $1.value }
        guard total > 0 else { return [IntentFuture(kind: .continueWriting, weight: 1)] }
        return ranked.map { IntentFuture(kind: $0.key, weight: $0.value / total) }
    }

    /// Prompt-safe, content-free summary. It contains only fixed enum labels
    /// and rounded relative weights — never conversation or typed text.
    public static func promptHint(for futures: [IntentFuture]) -> String {
        guard !futures.isEmpty,
              !(futures.count == 1 && futures[0].kind == .continueWriting)
        else { return "" }
        return futures.map { future in
            "\(future.kind.rawValue):\(Int((future.weight * 100).rounded()))"
        }.joined(separator: ", ")
    }

    private static func currentFragment(in text: String) -> String {
        let tail = text.suffix(96)
        if let newline = tail.lastIndex(of: "\n") { return String(tail[tail.index(after: newline)...]) }
        return String(tail)
    }

    private static func folded(_ text: String) -> String {
        text.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: englishLocale)
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func looksLikeQuestion(_ text: String) -> Bool {
        text.contains("?") || ["who ", "what ", "when ", "where ", "why ", "how ", "can you ", "could you ", "would you ", "do you ", "are you ", "is it "]
            .contains(where: { text.hasPrefix($0) })
    }

    private static func asksForCommitment(_ text: String) -> Bool {
        ["can you ", "could you ", "would you ", "will you ", "are you able", "does ", "work for you", "still coming", "make it", "send ", "have it by"]
            .contains(where: { text.contains($0) })
    }

    private static func asksForOpinion(_ text: String) -> Bool {
        ["what do you think", "thoughts", "your take", "do you think", "how do you feel", "would you rather"]
            .contains(where: { text.contains($0) })
    }

    /// Cues shorter than 3 letters ("y", "no") are dropped from the cue
    /// lists above rather than matched here: even on a whole-word boundary
    /// a one- or two-letter fragment is too often the true start of a
    /// longer, unrelated word ("no" vs. "not"/"nobody") to serve as
    /// reliable early-typing evidence, and the two- and three-letter
    /// alternatives already in each list ("yes"/"yep"/"yeah", "nah")
    /// cover the same intent without that ambiguity.
    private static func hasAnyPrefix(_ text: String, _ cues: [String]) -> Bool {
        guard !text.isEmpty else { return false }
        let word = String(text.prefix { $0 != " " })
        return cues.contains { cue in
            guard !cue.contains(" ") else {
                // Multi-word phrase cues ("sounds good", "do you mean")
                // stay a whole-string two-way prefix match: either the
                // phrase has already appeared, or the user hasn't finished
                // typing it yet.
                return text.hasPrefix(cue) || cue.hasPrefix(text)
            }
            // A single-word cue must land on the user's actual first
            // word — either they've finished typing exactly that word, or
            // they're still typing it and haven't gone past its length
            // yet. A longer, different first word that merely starts with
            // the same letters ("not" vs. "no", "you" vs. "yes") must
            // never match.
            return word == cue || (word.count < cue.count && cue.hasPrefix(word))
        }
    }
}
