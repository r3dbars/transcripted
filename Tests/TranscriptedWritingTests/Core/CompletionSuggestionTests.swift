import Testing
@testable import TranscriptedWritingCore

@Suite("Completion suggestion")
struct CompletionSuggestionTests {
    @Test("Rejects a first token that exceeds the character cap")
    func rejectsOverCapFirstToken() {
        #expect(
            CompletionSuggestion(
                text: "extraordinary",
                maxVisibleCharacters: 5
            ).visibleText.isEmpty
        )
        #expect(
            CompletionSuggestion(
                text: " extraordinary",
                maxVisibleCharacters: 6
            ).visibleText.isEmpty
        )
    }

    @Test("Character cap keeps only complete words")
    func characterCapKeepsCompleteWords() {
        #expect(
            CompletionSuggestion(
                text: " one two",
                maxVisibleCharacters: 5
            ).visibleText == " one"
        )
        #expect(
            CompletionSuggestion(
                text: " one two",
                maxVisibleCharacters: 4
            ).visibleText == " one"
        )
    }

    @Test("Word cap and dangling-tail repair remain intact")
    func preservesWordCapAndDanglingTailRepair() {
        #expect(
            CompletionSuggestion(
                text: " one two three four",
                maxVisibleWords: 3,
                maxVisibleCharacters: 100
            ).visibleText == " one two three"
        )
        #expect(
            CompletionSuggestion(
                text: " see if you had any thoughts on the details.",
                maxVisibleWords: 8,
                maxVisibleCharacters: 100
            ).visibleText == " see if you had any thoughts"
        )
    }


    @Test("Lab can observe the un-repaired capped tail")
    func allowsDanglingTailAblation() {
        #expect(
            CompletionSuggestion(
                text: " thoughts on the details",
                maxVisibleWords: 3,
                maxVisibleCharacters: 100,
                repairsDanglingTail: false
            ).visibleText == " thoughts on the"
        )
    }
}
