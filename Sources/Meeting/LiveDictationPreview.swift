import Foundation

/// What the island's dictation hover shows while you talk: the words so far
/// and the few the decoder may still rewrite. Provisional; the take is
/// transcribed again on release and only that text is pasted.
struct LiveDictationPreview: Equatable, Sendable {
    var settled = ""
    var tentative = ""

    var isEmpty: Bool { settled.isEmpty && tentative.isEmpty }

    mutating func commit(_ text: String) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        tentative = ""
        guard !trimmed.isEmpty else { return }
        settled = settled.isEmpty ? trimmed : settled + " " + trimmed
    }
}

extension LiveDictationPreview {
    /// Which words read as settled and which as still being heard. The
    /// decoder's partial is all provisional, but only its last couple of
    /// words really move, so only those are dimmed.
    func split(dimmingLast count: Int) -> (settled: String, tentative: String) {
        let partialWords = tentative.split(whereSeparator: \.isWhitespace).map(String.init)
        let dimmed = min(max(0, count), partialWords.count)
        let steady = partialWords.dropLast(dimmed).joined(separator: " ")
        let settledText = [settled, steady].filter { !$0.isEmpty }.joined(separator: " ")
        return (settledText, partialWords.suffix(dimmed).joined(separator: " "))
    }
}
