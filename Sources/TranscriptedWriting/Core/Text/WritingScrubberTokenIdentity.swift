import Foundation

/// Gives existing redactions identities while the scrubber runs. A later rule
/// may swallow an old token and emit a replacement of the same kind; counting
/// token kinds before and after cannot distinguish that from no redaction.
/// The private identities preserve token boundaries and are removed before any
/// result leaves Core. Same-length markers avoid collisions with input and do
/// not change the length thresholds used to classify surrounding text.
struct WritingScrubberTokenIdentity {
    typealias Kind = WritingSecretScrubber.Kind
    private static let pattern = try! NSRegularExpression(pattern: #"\x{27E8}redacted:([a-z-]+)\x{27E9}"#)
    let markedText: String
    private let originals: [String: String]

    init(_ text: String) {
        let matches = Self.pattern.matches(in: text, range: NSRange(text.startIndex..., in: text))
        var marked = text
        var tokens: [String: String] = [:]
        var identities: [String: String] = [:]
        for match in matches.reversed() {
            guard let range = Range(match.range, in: marked),
                  let sourceRange = Range(match.range, in: text),
                  let kindRange = Range(match.range(at: 1), in: text) else { continue }
            let original = String(text[sourceRange])
            let kind = String(text[kindRange])
            // Repeated old tokens can share an identity: only distinguishing
            // old tokens from newly emitted tokens matters, not their index.
            let token: String
            if let existing = identities[original] {
                token = existing
            } else if Kind(rawValue: kind) == nil && !Self.isPasswordToken(original) {
                // Rules never emit unknown kinds, so these already identify
                // themselves. Reserving them also prevents marker collisions.
                token = original
            } else {
                var number = 0
                var candidate: String
                repeat {
                    var value = number
                    var letters = Array(repeating: Character("a"), count: kind.count)
                    for index in letters.indices.reversed() {
                        letters[index] = Character(UnicodeScalar(97 + value % 26)!)
                        value /= 26
                    }
                    // A password identity stays recognizable to prompt rules.
                    if kind == "password" { letters[0] = "p" }
                    else if kind.count == 8 { letters[0] = "x" }
                    // Preserve punctuation as well as character/UTF-16 length.
                    for (index, character) in kind.enumerated() where character == "-" {
                        letters[index] = "-"
                    }
                    candidate = "⟨redacted:" + String(letters) + "⟩"
                    number += 1
                } while text.contains(candidate) || tokens[candidate] != nil
                    || Kind(rawValue: String(candidate.dropFirst(10).dropLast())) != nil
                token = candidate
            }
            identities[original] = token
            tokens[token] = original
            marked.replaceSubrange(range, with: token)
        }
        markedText = marked
        originals = tokens
    }

    static func isPasswordToken(_ text: String) -> Bool {
        text == WritingSecretScrubber.token(for: .password)
            || (text.hasPrefix("⟨redacted:p") && text.hasSuffix("⟩") && text.count == 19)
    }

    func result(from marked: String) -> WritingSecretScrubber.Result {
        let matches = Self.pattern.matches(in: marked, range: NSRange(marked.startIndex..., in: marked))
        var clean = ""
        var cursor = marked.startIndex
        var kinds: [Kind] = []
        for match in matches {
            guard let range = Range(match.range, in: marked),
                  let kindRange = Range(match.range(at: 1), in: marked) else { continue }
            clean += marked[cursor..<range.lowerBound]
            let token = String(marked[range])
            if let original = originals[token] {
                clean += original
            } else {
                clean += token
                kinds.append(Kind(rawValue: String(marked[kindRange])) ?? .secret)
            }
            cursor = range.upperBound
        }
        clean += marked[cursor...]
        let stripped = Self.pattern.stringByReplacingMatches(in: clean, range: NSRange(clean.startIndex..., in: clean), withTemplate: "")
        return WritingSecretScrubber.Result(
            clean: clean,
            kinds: kinds,
            isOnlyRedactions: clean.contains("⟨redacted:") && !stripped.contains { $0.isLetter || $0.isNumber }
        )
    }
}
