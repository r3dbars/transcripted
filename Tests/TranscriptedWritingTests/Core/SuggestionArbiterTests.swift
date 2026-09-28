import Testing
@testable import TranscriptedWritingCore

@Suite("Suggestion arbiter")
struct SuggestionArbiterTests {
    @Test("Base silence cannot be overridden by a specialist")
    func preservesSilence() {
        let decision = SuggestionArbiter.choose(from: SuggestionCandidateSet([
            SuggestionCandidate(text: "yep", source: .personal, confidence: 1, support: 10),
        ]))
        #expect(decision.candidate == nil)
        #expect(decision.reason == .silence)
    }

    @Test("Expert agreement keeps the longer base continuation")
    func agreement() {
        let decision = SuggestionArbiter.choose(from: SuggestionCandidateSet([
            SuggestionCandidate(text: "Tomorrow works for me", source: .base),
            SuggestionCandidate(text: "tomorrow", source: .personal, confidence: 1, support: 4),
        ]))
        #expect(decision.candidate?.text == "Tomorrow works for me")
        #expect(decision.reason == .expertsAgree)
    }

    @Test("Strong personal evidence can beat a generic disagreement")
    func personalWins() {
        let decision = SuggestionArbiter.choose(from: SuggestionCandidateSet([
            SuggestionCandidate(text: "afternoon works", source: .base),
            SuggestionCandidate(text: "tomorrow", source: .personal, confidence: 0.75, support: 3),
        ]))
        #expect(decision.candidate?.text == "tomorrow")
        #expect(decision.reason == .personalEvidence)
    }

    @Test("Weak personal evidence falls back to base")
    func weakPersonalFallsBack() {
        let decision = SuggestionArbiter.choose(from: SuggestionCandidateSet([
            SuggestionCandidate(text: "sounds good", source: .base),
            SuggestionCandidate(text: "yep", source: .personal, confidence: 0.5, support: 8),
        ]))
        #expect(decision.candidate?.text == "sounds good")
        #expect(decision.reason == .baseFallback)
    }
}
