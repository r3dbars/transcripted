import Foundation
import Testing
@testable import TranscriptedWritingCore

@Suite("Personal suggestion serving policy")
struct PersonalSuggestionPolicyTests {
    @Test("A confident personal word that disagrees replaces the ghost")
    func disagreementReplacesWithSinglePersonalWord() {
        let result = PersonalSuggestionPolicy.apply(
            baseGhost: "afternoon works great for me",
            personalPrediction: PersonalNextWordPrediction(word: "tomorrow", support: 4, total: 4)
        )
        #expect(result.text == "tomorrow")
        #expect(result.source == .personal)
    }

    @Test("Agreement keeps the base ghost untouched, including its extra words")
    func agreementKeepsTheLongerBaseGhost() {
        let result = PersonalSuggestionPolicy.apply(
            baseGhost: "Tomorrow works great for me",
            personalPrediction: PersonalNextWordPrediction(word: "tomorrow", support: 3, total: 3)
        )
        #expect(result.text == "Tomorrow works great for me")
        #expect(result.source == .agreed)
    }

    @Test("No personal candidate serves the base ghost untouched")
    func noPersonalCandidateServesBase() {
        let result = PersonalSuggestionPolicy.apply(baseGhost: "sounds good", personalPrediction: nil)
        #expect(result.text == "sounds good")
        #expect(result.source == .base)
    }

    @Test("An empty base ghost is never turned into a suggestion")
    func emptyBaseGhostStaysSilent() {
        let result = PersonalSuggestionPolicy.apply(
            baseGhost: "",
            personalPrediction: PersonalNextWordPrediction(word: "tomorrow", support: 4, total: 4)
        )
        #expect(result.text.isEmpty)
        #expect(result.source == .base)
    }

    @Test("Candidate handoff carries base and personal evidence without changing serving")
    func candidateHandoff() {
        let set = PersonalSuggestionPolicy.candidateSet(
            baseGhost: "sounds good to me",
            personalPrediction: PersonalNextWordPrediction(word: "yep", support: 3, total: 4)
        )
        #expect(set.candidates.map(\.source) == [.base, .personal])
        #expect(set.first(from: .personal)?.support == 3)
        #expect(set.first(from: .personal)?.confidence == 0.75)
    }

    @Test("tailWords takes the trailing letter-run tokens, bounded by maximumWords")
    func tailWordsTrailingBounded() {
        #expect(PersonalSuggestionPolicy.tailWords(fromContext: "See you Tomorrow, ") == ["you", "Tomorrow"])
        #expect(
            PersonalSuggestionPolicy.tailWords(fromContext: "one two three four ", maximumWords: 3)
                == ["two", "three", "four"]
        )
        #expect(PersonalSuggestionPolicy.tailWords(fromContext: "solo ") == ["solo"])
    }

    @Test("tailWords splits contractions the same way training does: two tokens, not one")
    func tailWordsSplitsContractions() {
        // PersonalNextWordShadow learns "don't" as the two letter-run
        // tokens ["don", "t"] — an apostrophe is neither a letter nor a
        // combining mark, so it separates tokens exactly like whitespace.
        // Serving must produce the same keys or a trained model can never
        // match after any contraction, hyphenated word, or word with a
        // digit in it.
        #expect(PersonalSuggestionPolicy.tailWords(fromContext: "I don't ") == ["don", "t"])
        #expect(PersonalSuggestionPolicy.tailWords(fromContext: "let's meet up ") == ["meet", "up"])
    }
}
