/// Keeps Tilde quiet until the writer has supplied enough intent in the
/// current editing session to ground a useful suggestion.
public enum SuggestionActivationPolicy {
    public static let minimumTypedCharacters = 3

    public static func allowsSuggestions(
        afterUserTyped text: String,
        trailingTextAfterCaret: String
    ) -> Bool {
        guard isAtGrowingEdge(trailingTextAfterCaret: trailingTextAfterCaret) else {
            return false
        }

        var meaningfulCharacters = 0
        for character in text where character.isLetter || character.isNumber {
            meaningfulCharacters += 1
            if meaningfulCharacters >= minimumTypedCharacters {
                return true
            }
        }
        return false
    }

    /// Tilde is a continuation tool, not an infill editor. Existing content on
    /// the current line means the writer moved back to repair text, so ghosts
    /// must stay out of the document. Later lines do not block suggestions.
    public static func isAtGrowingEdge(trailingTextAfterCaret: String) -> Bool {
        let currentLine = trailingTextAfterCaret.prefix { !$0.isNewline }
        return !currentLine.contains { !$0.isWhitespace }
    }
}
