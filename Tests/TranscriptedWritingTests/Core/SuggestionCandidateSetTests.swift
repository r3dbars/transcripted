import Testing
@testable import TranscriptedWritingCore

@Suite("Suggestion candidate set")
struct SuggestionCandidateSetTests {
    @Test("Keeps distinct experts in stable order")
    func stableOrder() {
        let set = SuggestionCandidateSet([
            SuggestionCandidate(text: "sounds good", source: .base),
            SuggestionCandidate(text: "yep", source: .personal, confidence: 1.4, support: 4),
        ])
        #expect(set.candidates.map(\.source) == [.base, .personal])
        #expect(set.first(from: .personal)?.confidence == 1)
    }

    @Test("Preserves cross-expert agreement but collapses same-expert duplicates")
    func deduplicatesWithinExpertOnly() {
        let set = SuggestionCandidateSet([
            SuggestionCandidate(text: "  ", source: .base),
            SuggestionCandidate(text: "Tomorrow", source: .base),
            SuggestionCandidate(text: " tomorrow ", source: .base),
            SuggestionCandidate(text: " tomorrow ", source: .personal, support: 8),
        ])
        #expect(set.candidates.count == 2)
        #expect(set.candidates.map(\.source) == [.base, .personal])
    }

    @Test("Negative support and confidence are clamped")
    func clampsHints() {
        let candidate = SuggestionCandidate(text: "yep", source: .personal, confidence: -0.2, support: -3)
        #expect(candidate.confidence == 0)
        #expect(candidate.support == 0)
    }
}
