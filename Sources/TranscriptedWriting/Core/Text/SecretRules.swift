import Foundation

/// Deterministic, regex/checksum-based secret detection for text that is
/// about to be persisted or joined into a completion prompt. This is the
/// RULES layer only — a fast, fully-tested first pass over structurally
/// recognizable secrets (credit cards, IBANs, SSNs, API-key shapes, JWTs,
/// PEM blocks) plus optionally email/phone. A model-based layer (GLiNER)
/// runs after this, app-side, to catch freeform PII the rules can't see
/// structurally. Everything here is pure and has no knowledge of where the
/// text came from or where it is going.
public enum SecretRules {
    /// The shape a rule matched. Used both to label the replacement token
    /// and to identify which rule fired in a `Finding`. Several distinct
    /// rules (AWS/OpenAI/GitHub/generic high-entropy) share `.apiKey`
    /// because the plan groups them as one "API-key shapes" concept and the
    /// persisted token should not advertise which provider leaked.
    public enum SecretType: String, Equatable, Sendable, CaseIterable {
        case creditCard = "card"
        case iban = "iban"
        case ssn = "ssn"
        case apiKey = "api-key"
        case jwt = "jwt"
        case pem = "pem"
        case email = "email"
        case phone = "phone"
    }

    /// One accepted redaction. Carries only the type, never the matched
    /// text — findings are safe to log or count.
    public struct Finding: Equatable, Sendable {
        public let type: SecretType

        public init(type: SecretType) {
            self.type = type
        }
    }

    /// Which optional categories participate. Structured secrets (card,
    /// IBAN, SSN, API-key shapes, JWT, PEM) are always scrubbed regardless
    /// of this config — only email/phone are configurable, since they are
    /// also genuinely useful personal vocabulary.
    public struct ScrubConfig: Equatable, Sendable {
        public var scrubEmails: Bool
        public var scrubPhones: Bool

        public init(scrubEmails: Bool, scrubPhones: Bool) {
            self.scrubEmails = scrubEmails
            self.scrubPhones = scrubPhones
        }

        /// Text about to be written into the encrypted Personal History
        /// store. Default per the Screen Memory plan: scrub emails/phones.
        public static let forPersistence = ScrubConfig(scrubEmails: true, scrubPhones: true)

        /// Text about to join a completion prompt (never written to disk
        /// from this path). Structured secrets still never survive; email
        /// and phone are kept since they can be genuinely useful context.
        public static let forPromptContext = ScrubConfig(scrubEmails: false, scrubPhones: false)
    }

    private static let replacementOpen = "\u{27E8}redacted:"
    private static let replacementClose = "\u{27E9}"

    /// Scrubs every recognized secret out of `text`, replacing each with a
    /// `⟨redacted:type⟩` token. Matches from different rules never overlap
    /// in the result: when two rules claim the same span the earliest,
    /// then longest, then highest-priority match wins and the rest are
    /// dropped rather than double-redacted.
    public static func scrub(_ text: String, config: ScrubConfig = .forPersistence) -> (clean: String, findings: [Finding]) {
        guard !text.isEmpty else { return (text, []) }

        var candidates: [(range: Range<String.Index>, type: SecretType, priority: Int)] = []
        for rule in rules(for: config) {
            for range in rule.matches(text) where !range.isEmpty {
                candidates.append((range, rule.type, rule.priority))
            }
        }
        guard !candidates.isEmpty else { return (text, []) }

        candidates.sort { lhs, rhs in
            if lhs.range.lowerBound != rhs.range.lowerBound {
                return lhs.range.lowerBound < rhs.range.lowerBound
            }
            let lhsLength = text.distance(from: lhs.range.lowerBound, to: lhs.range.upperBound)
            let rhsLength = text.distance(from: rhs.range.lowerBound, to: rhs.range.upperBound)
            if lhsLength != rhsLength { return lhsLength > rhsLength }
            return lhs.priority < rhs.priority
        }

        var accepted: [(range: Range<String.Index>, type: SecretType)] = []
        var cursor = text.startIndex
        for candidate in candidates where candidate.range.lowerBound >= cursor {
            accepted.append((candidate.range, candidate.type))
            cursor = candidate.range.upperBound
        }
        guard !accepted.isEmpty else { return (text, []) }

        var clean = ""
        var findings: [Finding] = []
        var walker = text.startIndex
        for match in accepted {
            clean += text[walker..<match.range.lowerBound]
            clean += replacementOpen + match.type.rawValue + replacementClose
            findings.append(Finding(type: match.type))
            walker = match.range.upperBound
        }
        clean += text[walker...]
        return (clean, findings)
    }

    // MARK: - Rule table

    private struct Rule {
        let type: SecretType
        let priority: Int
        let matches: (String) -> [Range<String.Index>]
    }

    private static func rules(for config: ScrubConfig) -> [Rule] {
        var list: [Rule] = [
            Rule(type: .pem, priority: 0, matches: pemMatches),
            Rule(type: .jwt, priority: 1, matches: jwtMatches),
            Rule(type: .iban, priority: 2, matches: ibanMatches),
            Rule(type: .creditCard, priority: 3, matches: creditCardMatches),
            Rule(type: .ssn, priority: 4, matches: ssnMatches),
            Rule(type: .apiKey, priority: 5, matches: awsAccessKeyMatches),
            Rule(type: .apiKey, priority: 6, matches: openAIKeyMatches),
            Rule(type: .apiKey, priority: 7, matches: githubTokenMatches),
            Rule(type: .apiKey, priority: 8, matches: highEntropyTokenMatches),
        ]
        if config.scrubEmails {
            list.append(Rule(type: .email, priority: 9, matches: emailMatches))
        }
        if config.scrubPhones {
            list.append(Rule(type: .phone, priority: 10, matches: phoneMatches))
        }
        return list
    }

    // MARK: - Individual rules

    private static func pemMatches(_ text: String) -> [Range<String.Index>] {
        regexMatches(
            text,
            pattern: #"-----BEGIN [A-Z0-9 ]+-----[\s\S]+?-----END [A-Z0-9 ]+-----"#
        )
    }

    private static func jwtMatches(_ text: String) -> [Range<String.Index>] {
        regexMatches(
            text,
            pattern: #"\beyJ[A-Za-z0-9_-]+\.[A-Za-z0-9_-]+\.[A-Za-z0-9_-]+\b"#
        )
    }

    /// Custom scan rather than a single greedy regex: a regex with an
    /// optional space between 2–4 char groups has no way to know when to
    /// stop, so it happily eats into whatever ordinary prose follows the
    /// real IBAN. Instead this walks forward from each `LL99` header,
    /// collecting alphanumeric characters (allowing single spaces as group
    /// separators, matching printed IBAN formatting), but only up to the
    /// exact length ISO 13616 mandates for that country code — never fewer,
    /// never more — then validates the mod-97 checksum on the complete
    /// candidate. Country codes outside the table are skipped rather than
    /// guessed at: accepting the first mod-97-valid *prefix* (the previous
    /// approach) can stop short of the true boundary purely by checksum
    /// coincidence, leaving trailing account digits of the real IBAN
    /// unredacted.
    private static func ibanMatches(_ text: String) -> [Range<String.Index>] {
        let headers = regexMatches(text, pattern: #"\b[A-Za-z]{2}\d{2}"#)
        var results: [Range<String.Index>] = []
        for header in headers {
            let countryCode = String(text[header.lowerBound]).uppercased()
                + String(text[text.index(after: header.lowerBound)]).uppercased()
            guard let expectedLength = ibanLengthByCountryCode[countryCode] else { continue }

            var alnum: [(character: Character, index: String.Index)] = []
            var index = header.lowerBound
            var sawSpace = false
            while index < text.endIndex, alnum.count < expectedLength {
                let char = text[index]
                if char.isLetter || char.isNumber {
                    alnum.append((char, index))
                    sawSpace = false
                } else if char == " ", !sawSpace, !alnum.isEmpty {
                    sawSpace = true
                } else {
                    break
                }
                index = text.index(after: index)
            }
            guard alnum.count == expectedLength,
                  isValidIBAN(String(alnum.map(\.character))) else { continue }
            let endIndex = text.index(after: alnum[alnum.count - 1].index)
            results.append(header.lowerBound..<endIndex)
        }
        return results
    }

    /// ISO 13616 fixed field length (letters + digits, spaces excluded) per
    /// IBAN country code. Deliberately exact rather than a min/max range:
    /// every issuing country has exactly one mandated length, and matching
    /// on anything else invites either under- or over-consumption.
    private static let ibanLengthByCountryCode: [String: Int] = [
        "AD": 24, "AE": 23, "AL": 28, "AT": 20, "AZ": 28, "BA": 20, "BE": 16, "BG": 22,
        "BH": 22, "BR": 29, "BY": 28, "CH": 21, "CR": 22, "CY": 28, "CZ": 24, "DE": 22,
        "DK": 18, "DO": 28, "EE": 20, "EG": 29, "ES": 24, "FI": 18, "FO": 18, "FR": 27,
        "GB": 22, "GE": 22, "GI": 23, "GL": 18, "GR": 27, "GT": 28, "HR": 21, "HU": 28,
        "IE": 22, "IL": 23, "IQ": 23, "IS": 26, "IT": 27, "JO": 30, "KW": 30, "KZ": 20,
        "LB": 28, "LC": 32, "LI": 21, "LT": 20, "LU": 20, "LV": 21, "LY": 25, "MC": 27,
        "MD": 24, "ME": 22, "MK": 19, "MR": 27, "MT": 31, "MU": 30, "NL": 18, "NO": 15,
        "PK": 24, "PL": 28, "PS": 29, "PT": 25, "QA": 29, "RO": 24, "RS": 22, "SA": 24,
        "SC": 31, "SE": 24, "SI": 19, "SK": 24, "SM": 27, "ST": 25, "SV": 28, "TL": 23,
        "TN": 24, "TR": 26, "UA": 29, "VA": 22, "VG": 24, "XK": 20,
    ]

    /// Custom scan for the same reason as `ibanMatches`: a single greedy
    /// regex followed by one Luhn check on the whole match has no way to
    /// stop before adjacent, differently-shaped digits (e.g. an expiry date
    /// separated by a space) that happen to fall inside the max digit-count
    /// window. `"4111 1111 1111 1111 12/26"` would otherwise absorb the
    /// expiry's `12` into an 18-digit candidate, fail Luhn as a whole, and
    /// leave the real 16-digit card number completely unredacted. Instead
    /// this walks forward from each digit run's start, then tries every
    /// plausible card length (13–19, longest first) against Luhn, accepting
    /// the first that validates — so a valid card prefix wins even when
    /// trailing unrelated digits made the maximal span invalid.
    private static func creditCardMatches(_ text: String) -> [Range<String.Index>] {
        let starts = regexMatches(text, pattern: #"(?<!\d)\d"#)
        var results: [Range<String.Index>] = []
        for start in starts {
            var digits: [(character: Character, index: String.Index)] = []
            var index = start.lowerBound
            var sawSeparator = false
            while index < text.endIndex, digits.count < 19 {
                let char = text[index]
                if char.isNumber {
                    digits.append((char, index))
                    sawSeparator = false
                } else if (char == " " || char == "-"), !sawSeparator, !digits.isEmpty {
                    sawSeparator = true
                } else {
                    break
                }
                index = text.index(after: index)
            }
            guard digits.count >= 13 else { continue }
            for length in stride(from: digits.count, through: 13, by: -1) {
                let candidate = String(digits.prefix(length).map(\.character))
                guard isValidLuhn(candidate) else { continue }
                let endIndex = text.index(after: digits[length - 1].index)
                results.append(start.lowerBound..<endIndex)
                break
            }
        }
        return results
    }

    private static func ssnMatches(_ text: String) -> [Range<String.Index>] {
        regexMatches(
            text,
            pattern: #"(?<!\d)\d{3}-\d{2}-\d{4}(?!\d)"#,
            validate: isValidSSNShape
        )
    }

    /// `AKIA` is a long-lived access key; `ASIA` is the temporary/STS variant
    /// (same 16-char suffix shape). Both must be caught here because at 20
    /// total characters neither is long enough to fall back on the generic
    /// ≥32-char high-entropy rule.
    private static func awsAccessKeyMatches(_ text: String) -> [Range<String.Index>] {
        regexMatches(text, pattern: #"\b(?:AKIA|ASIA)[0-9A-Z]{16}\b"#)
    }

    private static func openAIKeyMatches(_ text: String) -> [Range<String.Index>] {
        regexMatches(text, pattern: #"\bsk-[A-Za-z0-9_-]{20,}\b"#)
    }

    private static func githubTokenMatches(_ text: String) -> [Range<String.Index>] {
        regexMatches(text, pattern: #"\bgh[pousr]_[A-Za-z0-9]{36,}\b"#)
    }

    /// Generic high-entropy token, ≥32 characters with no whitespace, drawn
    /// from a base64-ish alphabet. Gated on character-class diversity and
    /// Shannon entropy so long English words, URLs, hex hashes, and UUIDs
    /// (all low-diversity or low-entropy) don't trip it — see the
    /// false-positive corpus test.
    ///
    /// Boundaries are defined by the token's own alphabet, not `\b`: `\b`
    /// only fires on a transition between `\w` and non-`\w`, but `+` and `/`
    /// (both legal leading/trailing base64 symbols) are themselves non-`\w`.
    /// A token starting with `+` preceded by whitespace has no `\w`/non-`\w`
    /// transition there, so `\b` silently declines to match at that
    /// position, the engine starts one character later, the token comes up
    /// one character short of 32, and the whole secret survives.
    private static func highEntropyTokenMatches(_ text: String) -> [Range<String.Index>] {
        regexMatches(
            text,
            pattern: #"(?<![A-Za-z0-9+/_=-])[A-Za-z0-9+/_=-]{32,}(?![A-Za-z0-9+/_=-])"#,
            validate: isHighEntropySecretShape
        )
    }

    private static func emailMatches(_ text: String) -> [Range<String.Index>] {
        regexMatches(
            text,
            pattern: #"\b[A-Za-z0-9._%+-]+@[A-Za-z0-9-]+(?:\.[A-Za-z0-9-]+)*\.[A-Za-z]{2,}\b"#
        )
    }

    /// Requires an explicit separator between digit groups (space, dot,
    /// dash, or parens around the area code) so a bare 10-digit run — an
    /// order number, an ID — never matches. The area code alternation
    /// treats a closing paren as a separator in its own right: `(415)`
    /// immediately followed by `555-2671` is a normal, common phone-number
    /// layout, not one that also needs a space/dot/dash after the `)`.
    private static func phoneMatches(_ text: String) -> [Range<String.Index>] {
        regexMatches(
            text,
            pattern: #"(?<!\d)(?:\+1[-.\s])?(?:\(\d{3}\)[-.\s]?|\d{3}[-.\s])\d{3}[-.\s]\d{4}(?!\d)"#
        )
    }

    // MARK: - Validators

    private static func isValidLuhn(_ raw: String) -> Bool {
        let digits = raw.compactMap(\.wholeNumberValue).filter { $0 >= 0 && $0 <= 9 }
        let digitCount = raw.filter(\.isNumber).count
        guard (13...19).contains(digitCount), digitCount == digits.count else { return false }
        var sum = 0
        var alternate = false
        for digit in digits.reversed() {
            var value = digit
            if alternate {
                value *= 2
                if value > 9 { value -= 9 }
            }
            sum += value
            alternate.toggle()
        }
        return sum % 10 == 0
    }

    private static func isValidSSNShape(_ raw: String) -> Bool {
        let parts = raw.split(separator: "-").map(String.init)
        guard parts.count == 3,
              let area = Int(parts[0]), let group = Int(parts[1]), let serial = Int(parts[2]) else {
            return false
        }
        guard area != 0, area != 666, area < 900 else { return false }
        guard group != 0 else { return false }
        guard serial != 0 else { return false }
        return true
    }

    private static func isValidIBAN(_ raw: String) -> Bool {
        let iban = raw.uppercased()
        guard (15...34).contains(iban.count) else { return false }
        guard iban.prefix(2).allSatisfy(\.isLetter), iban.dropFirst(2).prefix(2).allSatisfy(\.isNumber) else {
            return false
        }
        let rearranged = iban.dropFirst(4) + iban.prefix(4)
        var remainder = 0
        for char in rearranged {
            let value: Int
            if let digit = char.wholeNumberValue, char.isNumber {
                value = digit
            } else if char.isLetter, let ascii = char.asciiValue {
                value = Int(ascii) - Int(Character("A").asciiValue!) + 10
            } else {
                return false
            }
            for digit in String(value) {
                guard let d = digit.wholeNumberValue else { return false }
                remainder = (remainder * 10 + d) % 97
            }
        }
        return remainder == 1
    }

    /// `-` is deliberately NOT a diversity class of its own: it's the one
    /// base64url symbol that also shows up constantly in ordinary hyphenated
    /// text (UUIDs, ISO dates, invoice numbers, git hashes-with-dashes), so
    /// counting it would make those false-positive. True base64 punctuation
    /// (`+ / _ =`) still counts, and real secrets are almost always mixed
    /// upper/lower/digit anyway, so this costs little real recall.
    private static func isHighEntropySecretShape(_ raw: String) -> Bool {
        guard raw.count >= 32 else { return false }
        var hasUpper = false, hasLower = false, hasDigit = false, hasSymbol = false
        for char in raw {
            if char.isUppercase { hasUpper = true }
            else if char.isLowercase { hasLower = true }
            else if char.isNumber { hasDigit = true }
            else if "+/_=".contains(char) { hasSymbol = true }
        }
        let classCount = [hasUpper, hasLower, hasDigit, hasSymbol].filter { $0 }.count
        guard classCount >= 3 else { return false }
        return shannonEntropyPerCharacter(raw) >= 3.0
    }

    private static func shannonEntropyPerCharacter(_ s: String) -> Double {
        guard !s.isEmpty else { return 0 }
        var counts: [Character: Int] = [:]
        for char in s { counts[char, default: 0] += 1 }
        let total = Double(s.count)
        return counts.values.reduce(0.0) { accumulated, count in
            let probability = Double(count) / total
            return accumulated - probability * log2(probability)
        }
    }

    // MARK: - Regex plumbing

    private static func regexMatches(
        _ text: String,
        pattern: String,
        options: NSRegularExpression.Options = [],
        validate: (String) -> Bool = { _ in true }
    ) -> [Range<String.Index>] {
        guard let regex = try? NSRegularExpression(pattern: pattern, options: options) else { return [] }
        let nsText = text as NSString
        var results: [Range<String.Index>] = []
        regex.enumerateMatches(in: text, range: NSRange(location: 0, length: nsText.length)) { match, _, _ in
            guard let match, let range = Range(match.range, in: text) else { return }
            if validate(String(text[range])) {
                results.append(range)
            }
        }
        return results
    }
}
