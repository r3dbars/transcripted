import Foundation

/// One plausible continuation from one Tilde expert. Candidate text stays
/// memory-only; this value is never diagnostics-safe and must never be logged.
public struct SuggestionCandidate: Equatable, Sendable {
    public enum Source: String, Equatable, Hashable, Sendable {
        case base
        case personal
        case screen
        case episodic
        case intent
    }

    public let text: String
    public let source: Source
    /// A source-local confidence hint in 0...1. It is deliberately optional:
    /// scores from different experts are not assumed to be calibrated yet.
    public let confidence: Double?
    /// Small, non-text evidence counts that an arbiter can use later without
    /// retaining or logging personal content.
    public let support: Int

    public init(text: String, source: Source, confidence: Double? = nil, support: Int = 0) {
        self.text = text
        self.source = source
        self.confidence = confidence.map { min(max($0, 0), 1) }
        self.support = max(0, support)
    }
}

/// The production hand-off between candidate generation and selection.
/// Duplicate text from DIFFERENT experts is intentionally preserved: agreement
/// is evidence the arbiter needs. Only empty candidates and duplicate outputs
/// from the same expert are collapsed.
public struct SuggestionCandidateSet: Equatable, Sendable {
    public let candidates: [SuggestionCandidate]

    public init(_ candidates: [SuggestionCandidate]) {
        struct Key: Hashable { let source: SuggestionCandidate.Source; let text: String }
        var seen = Set<Key>()
        self.candidates = candidates.filter { candidate in
            let text = Self.normalized(candidate.text)
            guard !text.isEmpty else { return false }
            return seen.insert(Key(source: candidate.source, text: text)).inserted
        }
    }

    public var isEmpty: Bool { candidates.isEmpty }

    public func first(from source: SuggestionCandidate.Source) -> SuggestionCandidate? {
        candidates.first { $0.source == source }
    }

    private static func normalized(_ text: String) -> String {
        text.trimmingCharacters(in: .whitespacesAndNewlines)
            .precomposedStringWithCanonicalMapping
            .lowercased()
    }
}
