import Foundation

struct DictationFillerCleanupResult: Equatable {
    let text: String
    let removedCount: Int
    let changed: Bool
}

enum DictationFillerCleanupPolicy {
    private static let fillerRegex = try? NSRegularExpression(
        pattern: #"(?i)(?<![\p{L}\p{N}_])(?:um+|uh+|ah+|er+|erm+|hm+|hmm+)(?![\p{L}\p{N}_])[\s,.;:!?-]*"#
    )
    private static let leadingOpenerRegex = try? NSRegularExpression(
        pattern: #"(?i)^\s*(?:ok|okay|alright|all\s+right|so|well)[\s,.;:!?-]+"#
    )
    private static let duplicateWordRegex = try? NSRegularExpression(
        pattern: #"(?i)(?<![\p{L}\p{N}_])([\p{L}\p{N}']+)([ \t]+)\1(?![\p{L}\p{N}_])"#
    )
    private static let punctuationSpacingRegex = try? NSRegularExpression(
        pattern: #"\s+([,.;:!?])"#
    )
    private static let repeatedWhitespaceRegex = try? NSRegularExpression(
        pattern: #"[ \t]{2,}"#
    )
    private static let sentenceEndCharacters = CharacterSet(charactersIn: ".!?。！？")
    private static let protectedCharacters = CharacterSet(charactersIn: "`#[]{}<>|\\/@")

    static func clean(_ text: String) -> DictationFillerCleanupResult {
        let original = text
        var working = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !working.isEmpty else {
            return DictationFillerCleanupResult(text: working, removedCount: 0, changed: false)
        }

        var removedCount = 0
        working = removingStandaloneFillers(from: working, removedCount: &removedCount)
        working = removingLeadingOpenerIfSafe(from: working, removedCount: &removedCount)
        working = collapsingDuplicateWords(in: working, removedCount: &removedCount)
        working = normalizeSpacing(in: working)
        working = addFinalPunctuationIfSafe(to: working)

        let changed = working != original.trimmingCharacters(in: .whitespacesAndNewlines) || removedCount > 0
        return DictationFillerCleanupResult(text: working, removedCount: removedCount, changed: changed)
    }

    private static func removingStandaloneFillers(from text: String, removedCount: inout Int) -> String {
        replacingMatches(regex: fillerRegex, in: text) { match in
            removedCount += 1
            return replacementSpacer(for: match)
        }
    }

    private static func removingLeadingOpenerIfSafe(from text: String, removedCount: inout Int) -> String {
        guard wordCount(in: text) >= 5 else { return text }
        return replacingMatches(regex: leadingOpenerRegex, in: text, limit: 1) { _ in
            removedCount += 1
            return ""
        }
    }

    private static func collapsingDuplicateWords(in text: String, removedCount: inout Int) -> String {
        var current = text
        while true {
            var collapsed = false
            let next = replacingMatches(regex: duplicateWordRegex, in: current, limit: 1) { match in
                guard match.numberOfRanges >= 3,
                      let fullRange = Range(match.range(at: 0), in: current),
                      let wordRange = Range(match.range(at: 1), in: current),
                      let spacerRange = Range(match.range(at: 2), in: current) else {
                    return matchText(match, in: current)
                }

                let fullText = String(current[fullRange])
                guard !fullText.contains(where: { ",.;:!?".contains($0) }) else {
                    return fullText
                }

                collapsed = true
                removedCount += 1
                return String(current[wordRange]) + String(current[spacerRange])
            }

            current = next
            if !collapsed {
                return current
            }
        }
    }

    private static func normalizeSpacing(in text: String) -> String {
        let withoutPunctuationSpaces = replacingMatches(regex: punctuationSpacingRegex, in: text) { match in
            guard match.numberOfRanges >= 2,
                  let punctuationRange = Range(match.range(at: 1), in: text) else {
                return matchText(match, in: text)
            }
            return String(text[punctuationRange])
        }

        let collapsedWhitespace = replacingMatches(regex: repeatedWhitespaceRegex, in: withoutPunctuationSpaces) { _ in
            " "
        }

        return collapsedWhitespace.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func addFinalPunctuationIfSafe(to text: String) -> String {
        guard shouldAddFinalPunctuation(to: text) else { return text }
        return text + "."
    }

    private static func shouldAddFinalPunctuation(to text: String) -> Bool {
        guard wordCount(in: text) >= 6 else { return false }
        guard text.rangeOfCharacter(from: protectedCharacters) == nil else { return false }
        guard !text.contains("\n") else { return false }
        guard let lastScalar = text.unicodeScalars.last else { return false }
        guard !sentenceEndCharacters.contains(lastScalar) else { return false }
        guard !CharacterSet(charactersIn: ",;:-").contains(lastScalar) else { return false }
        return true
    }

    private static func replacementSpacer(for match: NSTextCheckingResult) -> String {
        guard match.range.location > 0 else { return "" }
        return " "
    }

    private static func replacingMatches(
        regex: NSRegularExpression?,
        in text: String,
        limit: Int? = nil,
        replacement: (NSTextCheckingResult) -> String
    ) -> String {
        guard let regex else { return text }
        let fullRange = NSRange(text.startIndex..<text.endIndex, in: text)
        let matches = regex.matches(in: text, range: fullRange)
        let selectedMatches = limit.map { Array(matches.prefix($0)) } ?? matches
        guard !selectedMatches.isEmpty else { return text }

        var result = text
        for match in selectedMatches.reversed() {
            guard let range = Range(match.range, in: result) else { continue }
            result.replaceSubrange(range, with: replacement(match))
        }
        return result
    }

    private static func matchText(_ match: NSTextCheckingResult, in text: String) -> String {
        guard let range = Range(match.range, in: text) else { return "" }
        return String(text[range])
    }

    private static func wordCount(in text: String) -> Int {
        text.split { !$0.isLetter && !$0.isNumber }.count
    }
}
