import Testing
@testable import TranscriptedWritingCore

@Suite("Suggestion activation")
struct SuggestionActivationPolicyTests {
    @Test("Empty and punctuation-only fields stay quiet")
    func emptyFieldsStayQuiet() {
        #expect(!SuggestionActivationPolicy.allowsSuggestions(
            afterUserTyped: "",
            trailingTextAfterCaret: ""
        ))
        #expect(!SuggestionActivationPolicy.allowsSuggestions(
            afterUserTyped: "  !?",
            trailingTextAfterCaret: ""
        ))
    }

    @Test("Fewer than three typed characters stays quiet")
    func shortInputStaysQuiet() {
        #expect(!SuggestionActivationPolicy.allowsSuggestions(
            afterUserTyped: "y",
            trailingTextAfterCaret: ""
        ))
        #expect(!SuggestionActivationPolicy.allowsSuggestions(
            afterUserTyped: "y e",
            trailingTextAfterCaret: ""
        ))
    }

    @Test("Existing document text does not count as newly typed intent")
    func existingDocumentDoesNotBypassSessionGate() {
        let existingDocument = "A long document already at the caret"
        #expect(existingDocument.count > SuggestionActivationPolicy.minimumTypedCharacters)
        #expect(!SuggestionActivationPolicy.allowsSuggestions(
            afterUserTyped: " ",
            trailingTextAfterCaret: ""
        ))
        #expect(!SuggestionActivationPolicy.allowsSuggestions(
            afterUserTyped: " a",
            trailingTextAfterCaret: ""
        ))
    }

    @Test("Three meaningful characters allow suggestions")
    func groundedInputAllowsSuggestions() {
        #expect(SuggestionActivationPolicy.allowsSuggestions(
            afterUserTyped: "yes",
            trailingTextAfterCaret: ""
        ))
        #expect(SuggestionActivationPolicy.allowsSuggestions(
            afterUserTyped: "y e s",
            trailingTextAfterCaret: ""
        ))
        #expect(SuggestionActivationPolicy.allowsSuggestions(
            afterUserTyped: "café",
            trailingTextAfterCaret: ""
        ))
    }

    @Test("Existing content on the same line suppresses suggestions")
    func existingSameLineContentStaysQuiet() {
        for trailingText in [
            "tomorrow morning.",
            "   tomorrow morning.",
            ", which we discussed",
            ")",
            "😀 tomorrow",
        ] {
            #expect(!SuggestionActivationPolicy.isAtGrowingEdge(
                trailingTextAfterCaret: trailingText
            ))
            #expect(!SuggestionActivationPolicy.allowsSuggestions(
                afterUserTyped: "yes",
                trailingTextAfterCaret: trailingText
            ))
        }
    }

    @Test("End of the current line remains a growing edge")
    func currentLineEndAllowsSuggestions() {
        for trailingText in [
            "",
            "   ",
            "\nThe next paragraph starts here.",
            "   \nThe next paragraph starts here.",
        ] {
            #expect(SuggestionActivationPolicy.isAtGrowingEdge(
                trailingTextAfterCaret: trailingText
            ))
            #expect(SuggestionActivationPolicy.allowsSuggestions(
                afterUserTyped: "yes",
                trailingTextAfterCaret: trailingText
            ))
        }
    }
}
