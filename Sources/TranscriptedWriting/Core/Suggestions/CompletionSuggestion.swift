import Foundation

public struct CompletionSuggestion: Equatable, Sendable {
    public static let defaultMaxVisibleWords = 8
    public static let maximumVisibleWords = 20
    public static let defaultMaxVisibleCharacters = 42

    public let visibleText: String

    public init(
        text: String,
        maxVisibleWords: Int = Self.defaultMaxVisibleWords,
        maxVisibleCharacters: Int? = nil,
        repairsDanglingTail: Bool = true
    ) {
        let visibleWords = max(1, maxVisibleWords)
        let visibleCharacters = max(
            1,
            maxVisibleCharacters ?? Self.defaultMaxVisibleCharacters(forVisibleWords: visibleWords)
        )
        let capped = Self.cappedText(
            text,
            wordLimit: visibleWords,
            characterLimit: visibleCharacters
        )
        self.visibleText = repairsDanglingTail
            ? RawContinuationPrompt.repairDanglingTail(capped)
            : capped
    }

    private static func cappedText(
        _ text: String,
        wordLimit: Int,
        characterLimit: Int
    ) -> String {
        let singleLineText = String(text.prefix { !$0.isNewline })
        let wordCappedText = acceptedPrefix(in: singleLineText, wordLimit: wordLimit)
        return characterCappedText(wordCappedText, characterLimit: characterLimit)
    }

    static func acceptedPrefix(in text: String, wordLimit: Int) -> String {
        guard wordLimit > 0 else {
            return ""
        }

        var accepted = ""
        var wordCount = 0
        var isInsideWord = false

        for character in text {
            if character.isWhitespace {
                if wordCount >= wordLimit {
                    break
                }

                accepted.append(character)
                isInsideWord = false
                continue
            }

            if !isInsideWord {
                if wordCount >= wordLimit {
                    break
                }

                wordCount += 1
                isInsideWord = true
            }

            accepted.append(character)
        }

        return accepted
    }

    public static func clampedVisibleWords(_ value: Int) -> Int {
        min(maximumVisibleWords, max(1, value))
    }

    public static func defaultMaxVisibleCharacters(forVisibleWords visibleWords: Int) -> Int {
        max(defaultMaxVisibleCharacters, max(1, visibleWords) * 10)
    }

    private static func characterCappedText(_ text: String, characterLimit: Int) -> String {
        guard text.count > characterLimit else {
            return text
        }

        let cut = text.index(text.startIndex, offsetBy: characterLimit)
        let capped = String(text[..<cut])
        if text[cut].isWhitespace {
            return capped
        }

        guard let lastWhitespaceIndex = capped.lastIndex(where: { $0.isWhitespace }) else {
            return ""
        }

        let wordBoundaryCapped = String(capped[..<lastWhitespaceIndex])
        if wordBoundaryCapped.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return ""
        }

        return wordBoundaryCapped
    }
}
