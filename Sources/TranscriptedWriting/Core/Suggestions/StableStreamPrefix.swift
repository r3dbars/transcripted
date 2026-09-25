import Foundation

/// Decides which prefix of a streaming continuation is safe to show while
/// generation is still running. Only whitespace ends a word here — the same
/// definition `CompletionSuggestion` uses for acceptance — so a partial never
/// stops inside `10:30`, `1,000`, or `v1.2`.
public enum StableStreamPrefix {
    /// The longest run of complete words in `text` — everything before the
    /// last whitespace boundary, with that boundary trimmed — or `nil` when
    /// no complete word has arrived yet. Each result is a prefix of the next
    /// one, so a stream only ever grows the visible text.
    public static func prefix(of text: String) -> String? {
        var boundary: String.Index?
        var sawWord = false
        for index in text.indices {
            if text[index].isWhitespace {
                if sawWord { boundary = text.index(after: index) }
            } else {
                sawWord = true
            }
        }
        guard let boundary else { return nil }
        var prefix = String(text[..<boundary])
        while let last = prefix.last, last.isWhitespace { prefix.removeLast() }
        guard prefix.contains(where: { $0.isLetter || $0.isNumber }) else { return nil }
        return prefix
    }

    /// True when `piece` can move the boundary at all; lets callers skip
    /// re-cleaning the accumulated output for deltas inside a word.
    public static func mayAdvanceBoundary(_ piece: String) -> Bool {
        piece.contains(where: \.isWhitespace)
    }
}
