import Foundation

/// Gives existing redactions identities while the scrubber runs. A later rule
/// may swallow an old token and emit a replacement of the same kind; counting
/// token kinds before and after cannot distinguish that from no redaction.
/// The private identities preserve token boundaries and are removed before any
/// result leaves Core. Their prefix is chosen to avoid collisions with input.
struct WritingScrubberTokenIdentity {
    typealias Kind = WritingSecretScrubber.Kind
    private static let pattern = try! NSRegularExpression(pattern: #"\x{27E8}redacted:([a-z-]+)\x{27E9}"#)
    let markedText: String
    private let originals: [String: String]

    init(_ text: String) {
        var prefix = "existing-"
        while text.contains(prefix) { prefix += "existing-" }
        let matches = Self.pattern.matches(in: text, range: NSRange(text.startIndex..., in: text))
        var marked = text
        var tokens: [String: String] = [:]
        for (index, match) in matches.enumerated().reversed() {
            guard let range = Range(match.range, in: marked),
                  let kindRange = Range(match.range(at: 1), in: text) else { continue }
            // Alphabetic IDs stay inside the existing redaction-token grammar.
            var number = index
            var identifier = ""
            repeat {
                identifier.append(Character(UnicodeScalar(97 + number % 26)!))
                number /= 26
            } while number > 0
            let token = "⟨redacted:" + text[kindRange] + "-" + prefix + identifier + "⟩"
            tokens[token] = String(text[Range(match.range, in: text)!])
            marked.replaceSubrange(range, with: token)
        }
        markedText = marked
        originals = tokens
    }

    static func isPasswordToken(_ text: String) -> Bool {
        text == WritingSecretScrubber.token(for: .password)
            || (text.hasPrefix("⟨redacted:password-existing-") && text.hasSuffix("⟩"))
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
