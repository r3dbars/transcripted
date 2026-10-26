import Foundation

/// The inline rules (layer 3 in `WritingSecretScrubber`'s doc), the shared
/// patterns both rule layers read, and the regex plumbing. Moved unchanged
/// out of `WritingSecretScrubber.swift`.
extension WritingSecretScrubber {

    // MARK: - Layer 2: inline rules

    private struct Candidate {
        let range: Range<String.Index>
        let kind: Kind
        let priority: Int
    }

    static func applyInlineRules(_ text: String) -> String {
        var candidates: [Candidate] = []
        var priority = 0
        func add(_ pattern: NSRegularExpression, group: Int, kind: Kind, keep: (String, NSTextCheckingResult) -> Bool = { _, _ in true }) {
            priority += 1
            let rulePriority = priority
            enumerateMatches(text, pattern) { match in
                guard let range = valueRange(match, group: group, in: text) else { return }
                let value = String(text[range])
                // A value has at least one letter or digit: not `, ` between backticks.
                guard !value.hasPrefix(tokenOpen), value.contains(where: { $0.isLetter || $0.isNumber }),
                      keep(value, match) else { return }
                candidates.append(Candidate(range: range, kind: kind, priority: rulePriority))
            }
        }

        for pattern in tokenFormatPatterns { add(pattern, group: 0, kind: .apiKey) }
        for pattern in cardPatterns {
            add(pattern, group: 0, kind: .card) { value, _ in isCardNumber(value) }
            // `4111 1111 1111 1111 12/28 123`: the expiry and CVV typed
            // right after the number go with it.
            enumerateMatches(text, pattern) { match in
                guard let card = Range(match.range, in: text), isCardNumber(String(text[card])),
                      let tail = firstMatch(String(text[card.upperBound...]), cardTailPattern) else { return }
                let rest = String(text[card.upperBound...])
                for (group, kind) in [(1, Kind.card), (2, Kind.code)] {
                    guard let local = Range(tail.range(at: group), in: rest) else { continue }
                    let start = text.index(card.upperBound, offsetBy: rest.distance(from: rest.startIndex, to: local.lowerBound))
                    let end = text.index(start, offsetBy: rest.distance(from: local.lowerBound, to: local.upperBound))
                    candidates.append(Candidate(range: start..<end, kind: kind, priority: 0))
                }
            }
        }
        add(genericTokenPattern, group: 0, kind: .apiKey) { value, match in
            isRandomToken(value) && !isInsideURL(match.range, in: text)
        }
        add(urlCredentialPattern, group: 1, kind: .password)
        add(passwordLabelPattern, group: 2, kind: .password) { value, _ in isLikelySecretValue(value) }
        add(passwordIsPattern, group: 2, kind: .password) { value, _ in isLikelySecretValue(value) }
        add(passLabelPattern, group: 1, kind: .password) { value, _ in
            // `pass` is also a word ("cleanup pass: delete dead code") and a
            // name in code (`case .pass:`, `pass = 0`): only a value that
            // mixes letters with digits or a symbol counts.
            value.count >= 6 && value.contains(where: \.isLetter)
                && value.contains { $0.isNumber || strongSymbols.contains($0) }
                && !isPlaceholderOrCode(value)
        }
        add(pinPattern, group: 1, kind: .code) { _, match in !isCountedNumber(match, group: 1, in: text) }
        add(barePinPattern, group: 2, kind: .code) { _, match in
            // `PIN 4821`, a number that ends the line (`pin 4821`), or a pin
            // someone has (`my pin 4821 for the gate`); not pin the verb:
            // "pin 2025 roadmap to the channel".
            let label = substring(match, group: 1, in: text) ?? ""
            let after = (text as NSString).substring(from: match.range.location + match.range.length)
            let restOfLine = after.prefix { $0 != "\n" }
            let endsLine = restOfLine.allSatisfy { !$0.isLetter && !$0.isNumber }
            let before = (text as NSString).substring(to: match.range.location)
            let wordBefore = before.split(whereSeparator: \.isWhitespace).last.map { $0.lowercased() } ?? ""
            let owned = pinOwnerWords.contains(wordBefore) && before.last?.isWhitespace == true
            return (label == "PIN" || endsLine || owned) && !isCountedNumber(match, group: 2, in: text)
        }
        add(codeLabelPattern, group: 1, kind: .code) { value, _ in value.contains(where: isDigit) }
        add(otpLabelPattern, group: 1, kind: .code) { value, _ in value.contains(where: isDigit) }
        add(bareCodePattern, group: 2, kind: .code) { _, match in
            let before = substring(match, group: 1, in: text)?.lowercased() ?? ""
            return !notSecretCodeWords.contains(before) && !isCountedNumber(match, group: 2, in: text)
        }
        add(cvvLabelPattern, group: 1, kind: .code)
        add(cscLabelPattern, group: 2, kind: .code) { _, match in
            // `CSC 101` and `CID 2040` are course and case numbers: only
            // with a separator (`CSC: 123`) or a card on the line.
            let separator = substring(match, group: 1, in: text) ?? ""
            let line = lineContaining(match.range, in: text)
            return separator.contains(":") || separator.contains("=")
                || lineHoldsCard(line) || firstMatch(line, cardOnlyWordPattern) != nil
        }
        add(expiryLabelPattern, group: 1, kind: .card) { _, match in
            // "The offer expires 12/31" isn't a card's expiry.
            let line = lineContaining(match.range, in: text)
            return lineHoldsCard(line) || firstMatch(line, cardWordPattern) != nil
        }
        add(mysqlAttachedPattern, group: 1, kind: .password)
        add(sshpassPattern, group: 1, kind: .password)
        add(redisPattern, group: 1, kind: .password)
        add(curlUserPattern, group: 1, kind: .password)
        add(secretFlagPattern, group: 1, kind: .secret) { value, _ in
            !value.hasPrefix("-") && !isPlaceholderOrCode(value) && !matchesWhole(value, placeholderNamePattern)
        }
        add(bearerPattern, group: 1, kind: .secret) { value, _ in
            // Credentials, not hyphenated words: `bearer token-based` stays.
            !matchesWhole(value.lowercased(), placeholderNamePattern)
                && (value.contains { $0.isNumber || "+/=".contains($0) } || hasInnerUppercase(value))
        }
        add(basicPattern, group: 1, kind: .secret) { value, match in
            // `basic` is an everyday word ("basic JavaScript", "basic
            // end-to-end tests"): a Basic credential is a long base64 run,
            // or sits on a line that talks about auth.
            let line = lineContaining(match.range, in: text)
            if firstMatch(line, authMentionPattern) != nil {
                return !matchesWhole(value.lowercased(), placeholderNamePattern)
                    && (value.contains { $0.isNumber || "+/=".contains($0) } || hasInnerUppercase(value))
            }
            return value.count >= 16 && value.contains { $0.isNumber || "+/=".contains($0) }
        }
        add(secretKeyPattern, group: 3, kind: .secret) { value, match in
            let key = substring(match, group: 1, in: text) ?? ""
            let separator = substring(match, group: 2, in: text) ?? ""
            // `${API_TOKEN:-}` and `${PASS:=x}` are shell defaults, not values.
            if separator.hasPrefix(":"), let first = value.first, "-=+?".contains(first) { return false }
            guard isSecretKeyName(key), !isPlaceholderOrCode(value), value.lowercased() != key.lowercased(),
                  !matchesWhole(value, placeholderNamePattern), !matchesWhole(value, codeTypeValuePattern) else {
                return false
            }
            // Shell style, `SOME_TOKEN=value`: any real value.
            if separator == "=", matchesWhole(key, screamingKeyPattern) { return true }
            // A config key, `github_token: abc`: any value that isn't a
            // name with capitals in it (`accessToken: fetchedToken`).
            if key.contains("_") || key.contains("-") {
                let capitalizedName = value.contains(where: \.isUppercase) && matchesWhole(value, identifierValuePattern)
                return !capitalizedName
            }
            // A bare key in code or prose needs a digit or a symbol inside,
            // so `token: pasteToken` and `observerToken: Token?` stay.
            let body = value.trimmingCharacters(in: CharacterSet(charactersIn: "?!"))
            return body.count >= 4 && body.contains { $0.isNumber || strongSymbols.contains($0) }
        }

        guard !candidates.isEmpty else { return text }
        candidates.sort { lhs, rhs in
            if lhs.range.lowerBound != rhs.range.lowerBound { return lhs.range.lowerBound < rhs.range.lowerBound }
            let lhsLength = text.distance(from: lhs.range.lowerBound, to: lhs.range.upperBound)
            let rhsLength = text.distance(from: rhs.range.lowerBound, to: rhs.range.upperBound)
            if lhsLength != rhsLength { return lhsLength > rhsLength }
            return lhs.priority < rhs.priority
        }
        var output = ""
        var cursor = text.startIndex
        for candidate in candidates where candidate.range.upperBound > cursor {
            // One that starts inside the last token runs that token on to its own end.
            if candidate.range.lowerBound >= cursor { output += text[cursor..<candidate.range.lowerBound] + token(for: candidate.kind) }
            cursor = candidate.range.upperBound
        }
        output += text[cursor...]
        return output
    }

    /// The match's group, without quotes around it or sentence punctuation
    /// after it.
    private static func valueRange(_ match: NSTextCheckingResult, group: Int, in text: String) -> Range<String.Index>? {
        guard match.range(at: group).location != NSNotFound,
              let raw = Range(match.range(at: group), in: text) else { return nil }
        var lower = raw.lowerBound
        var upper = raw.upperBound
        let quotes: Set<Character> = ["\"", "'", "`"]
        if lower < upper, quotes.contains(text[lower]) { lower = text.index(after: lower) }
        // `(hunter22)`, `[hunter22]`: the brackets aren't the value.
        if lower < upper, "([".contains(text[lower]),
           let closing = text[lower..<upper].lastIndex(where: { ")]".contains($0) }) {
            lower = text.index(after: lower)
            upper = closing
        }
        while lower < upper {
            let last = text[text.index(before: upper)]
            // `!` and `?` stay: passwords end in them more often than
            // sentences put one right after a password.
            if quotes.contains(last) || ".,;)".contains(last) {
                upper = text.index(before: upper)
            } else {
                break
            }
        }
        return lower < upper ? lower..<upper : nil
    }

    static func substring(_ match: NSTextCheckingResult, group: Int, in text: String) -> String? {
        guard match.range(at: group).location != NSNotFound,
              let range = Range(match.range(at: group), in: text) else { return nil }
        return String(text[range])
    }

    /// Words that follow "password is" / "password:" in ordinary sentences.
    private static let commonValueWords: Set<String> = [
        "wrong", "right", "correct", "incorrect", "too", "not", "the", "a", "an", "my", "your", "his", "her",
        "their", "our", "its", "this", "that", "still", "now", "just", "also", "only", "expired", "required",
        "optional", "invalid", "valid", "same", "different", "case", "weak", "strong", "long", "short", "easy",
        "hard", "simple", "secure", "insecure", "safe", "unsafe", "saved", "stored", "reset", "changed", "set",
        "new", "old", "hidden", "visible", "missing", "empty", "blank", "none", "null", "nil", "unknown",
        "below", "above", "attached", "here", "there", "in", "on", "at", "for", "with", "without", "from",
        "same", "fine", "good", "bad", "great", "ok", "okay", "yes", "no", "what", "which", "whatever",
        "something", "nothing", "encrypted", "protected", "locked", "unlocked", "sensitive", "private",
        "public", "secret", "shared", "temporary", "default", "generated", "random", "unique", "complicated",
        "complex", "impossible", "annoying", "broken", "gone", "lost", "forgotten", "known", "unchanged",
        "different", "and", "or", "but", "so", "if", "because", "being", "been", "was", "is", "will", "can",
        "should", "must", "might", "manager", "field", "prompt", "policy", "requirements", "rules", "reset",
        "written", "printed", "taped", "stuck", "somewhere", "posted", "given", "taken", "chosen", "stolen",
        "forgotten", "shown", "sent", "texted", "emailed", "pinned",
    ]

    /// Type names, literals, variables and expressions: what follows
    /// `password:` or `apiKey =` in code, where the real value isn't typed.
    private static let codeValueWords: Set<String> = [
        "string", "str", "text", "int", "integer", "bool", "boolean", "data", "any", "object", "number",
        "char", "bytes", "securestring", "optional", "true", "false", "nil", "null", "none", "undefined",
        "password", "passwd", "passphrase", "passcode", "pwd", "pw", "token", "secret", "key", "apikey",
        "credentials", "credential", "value", "env", "bearer", "basic", "digest",
    ]

    static func isPlaceholderOrCode(_ value: String) -> Bool {
        let lower = value.lowercased()
        if codeValueWords.contains(lower.trimmingCharacters(in: CharacterSet(charactersIn: "?!,)"))) { return true }
        if let first = value.first, "<{[(%".contains(first) { return true }
        // `$VAR`, `${VAR}`, `$(cmd)`, `$password`: a variable, not the value.
        // `$unshine1` is a value.
        if value.hasPrefix("$") {
            let name = value.dropFirst()
            if name.hasPrefix("{") || name.hasPrefix("(") { return true }
            if !name.isEmpty, name.allSatisfy({ $0.isUppercase || $0.isNumber || $0 == "_" }) { return true }
            // `$db_pass`, `$pass`: a shell variable. A digit or a capital
            // inside (`$unshine1`) reads as a value.
            if !name.isEmpty, name.allSatisfy({ $0.isLowercase || $0 == "_" }) { return true }
            if codeValueWords.contains(name.lowercased()) { return true }
        }
        if value.contains("(") || value.hasSuffix("{") { return true }
        return ["self.", "this.", "process.env", "os.environ", "env[", "env.", "config.", "settings.", "secrets."]
            .contains { lower.hasPrefix($0) }
    }

    static func isLikelySecretValue(_ value: String) -> Bool {
        guard !value.isEmpty, !isPlaceholderOrCode(value) else { return false }
        if value.contains(where: { $0.isNumber }) { return true }
        if value.contains(where: { !$0.isLetter && !"-'\u{2019}".contains($0) }) { return true }
        if hasInnerUppercase(value) { return true }
        let lower = value.lowercased()
        guard lower.count >= 4, !commonValueWords.contains(lower) else { return false }
        return !(lower.hasSuffix("ing") || lower.hasSuffix("ed") || lower.hasSuffix("ly"))
    }

    private static func hasInnerUppercase(_ value: String) -> Bool {
        value.dropFirst().contains(where: \.isUppercase) && value.contains(where: \.isLowercase)
    }

    private static let secretKeyWords: Set<String> = [
        "password", "passwd", "pwd", "passphrase", "secret", "token", "apikey", "auth",
        "credential", "credentials", "authorization",
    ]

    private static let secretKeyJoins = ["apikey", "accesskey", "privatekey", "secretkey", "clientsecret", "authtoken"]

    /// `DB_PASSWORD`, `github_token`, `apiKey`, `x-api-key`, `AUTH`. Not
    /// `author` or `tokens_used`: the secret word has to be a whole part of
    /// the key.
    private static func isSecretKeyName(_ key: String) -> Bool {
        var parts: [String] = []
        var current = ""
        for character in key {
            if "_-.".contains(character) {
                if !current.isEmpty { parts.append(current) }
                current = ""
            } else if character.isUppercase, let last = current.last, last.isLowercase {
                parts.append(current)
                current = String(character)
            } else {
                current.append(character)
            }
        }
        if !current.isEmpty { parts.append(current) }
        let lowered = parts.map { $0.lowercased() }
        if lowered.contains(where: secretKeyWords.contains) { return true }
        // `PASS` only as a shell variable's last word (`SMTP_PASS`), not
        // `pass_count` or `mid-pass`.
        if lowered.count > 1, lowered.last == "pass", key == key.uppercased() { return true }
        let joined = lowered.joined()
        return secretKeyJoins.contains { joined.contains($0) }
    }

    // MARK: - Patterns

    static func regex(_ pattern: String, caseInsensitive: Bool = false) -> NSRegularExpression {
        // Every pattern here is a literal; a bad one is a programming error.
        try! NSRegularExpression(pattern: pattern, options: caseInsensitive ? [.caseInsensitive] : [])
    }

    /// A pattern that has to match the whole line.
    private static func wholeLine(_ pattern: String) -> NSRegularExpression {
        regex("^(?:" + pattern + ")$")
    }

    static let oneTimeCodePattern = wholeLine(#"\d{6,8}|\d{3}[ -]\d{3}|\d{4}[ -]\d{4}"#)
    static let shortCodePattern = wholeLine(#"\d{4,5}"#)
    static let cvvPattern = wholeLine(#"\d{3,4}"#)
    static let expiryPattern = wholeLine(#"(0?[1-9]|1[0-2]) ?/ ?(\d{4}|\d{2})"#)
    /// A line before a 4–5 digit line that makes it a code ("here's the
    /// code", "PIN?"). Lists of codes need `codeListPattern`.
    static let codeKeywordPattern = regex(
        #"\b(codes?|pin|otp|passcode|verification|verify|2fa|mfa|cvv|cvc|csc)\b"#,
        caseInsensitive: true
    )

    /// A line that heads a list of recovery codes.
    static let codeListPattern = regex(
        #"\b(?:backup|recovery|one[- ]time|2fa|mfa|emergency)[^\S\n]+codes\b"#,
        caseInsensitive: true
    )

    /// Lines that look like a password by character mix but are ordinary.
    static let notSecretPatterns: [NSRegularExpression] = [
        // Email.
        wholeLine(#"[A-Za-z0-9._%+-]+@[A-Za-z0-9-]+(\.[A-Za-z0-9-]+)*\.[A-Za-z]{2,}"#),
        // Host or file name: labels joined by dots, ending in a letter label.
        wholeLine(#"[A-Za-z0-9_-]+(\.[A-Za-z0-9_-]+)*\.[A-Za-z]{2,10}(/\S*)?"#),
        // Version.
        wholeLine(#"[vV]?\d+(\.\d+)+([-+][A-Za-z0-9.]+)?"#),
        // A name with a dotted version on it: `iOS26.1`, `HDMI2.1`, `Python3.12`.
        wholeLine(#"[A-Za-z]{1,12}\d+(\.\d+)+"#),
        // Date.
        wholeLine(#"\d{1,4}[-/.]\d{1,2}[-/.]\d{1,4}"#),
        // Time.
        wholeLine(#"\d{1,2}:\d{2}(:\d{2})?([aApP][mM])?"#),
        // Ticket or model ID: letters, a hyphen, digits (`JIRA-1234`,
        // `GPT-4o`).
        wholeLine(#"[A-Za-z]{2,10}-\d+[a-z]?"#),
        // Quarter or fiscal year: `Q3-2026`, `FY27`.
        wholeLine(#"(?:[Qq][1-4]|FY|fy)[-' ]?\d{2,4}"#),
        // Ordinal, amount with a unit, resolution.
        wholeLine(
            #"\d+(st|nd|rd|th|s|k|K|m|M|b|B|p|x|X|px|pt|em|rem|ms|fps|hz|Hz|kb|KB|mb|MB|gb|GB|tb|TB|mg|kg|km|mi|mph|am|pm|AM|PM|h|hr|hrs|min|mins|sec|secs|yr|yrs|GHz|MHz)"#
        ),
        // Git hash.
        wholeLine(#"[0-9a-f]{7,40}"#),
        // Slugs and dotted names with 3+ parts: `parakeet-tdt-0.6b-v3`, `speaker.cluster.eres2net`.
        wholeLine(#"[A-Za-z0-9_]+([.-][A-Za-z0-9_]+){2,}"#),
        // Member access in code: `audio.$status`, `item.identifier?.rawValue,`.
        wholeLine(#"[A-Za-z_$][A-Za-z0-9_$]*([?!]?\.[A-Za-z_$][A-Za-z0-9_$]*)+[?!]?[,;]?"#),
        // UUID.
        wholeLine(#"[0-9A-Fa-f]{8}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{12}"#),
    ]

    /// Tools people type with a version number on the end.
    static let versionedToolStems: Set<String> = [
        "python", "pip", "php", "ruby", "node", "gcc", "clang", "java", "perl", "lua", "llvm", "openssl",
        "postgres", "psql", "mysql", "redis", "http", "ipv", "utf", "md", "sha", "base", "vim", "emacs",
        "swift", "kotlin", "scala", "dotnet", "net", "ssh", "tls", "ssl", "gpt", "claude", "llama", "qwen",
    ]

    /// A line ending in a password label, with the value on the next line.
    /// Not `wifi:`, which is usually followed by the network's name.
    static let asksPasswordPattern = regex(
        #"\b(?:password|passwd|passcode|passphrase|pw|pin)[^\S\n]*:[^\S\n]*$"#,
        caseInsensitive: true
    )

    /// The words people build weak passwords from. `hunter22` and
    /// `Password123` count everywhere, not only in browsers.
    static let commonPasswordStems: Set<String> = [
        "password", "passw", "pass", "pwd", "qwerty", "qwertyuiop", "asdf", "asdfgh", "zxcvbn", "letmein",
        "welcome", "admin", "administrator", "root", "hunter", "dragon", "monkey", "iloveyou", "abc", "abcd",
        "abcdef", "secret", "master", "login", "football", "baseball", "sunshine", "shadow", "princess",
        "superman", "batman", "trustno", "changeme", "default", "test", "guest", "user", "p", "pw",
    ]

    /// A word with a number on the end: `Python3`, `macOS26`, `hunter22`.
    static let wordWithNumberPattern = wholeLine(#"[A-Za-z]{2,}\d{1,4}"#)

    /// A line that starts `identifier=` or `identifier:`.
    static let labelledLinePattern = regex(#"^["']?[A-Za-z_][A-Za-z0-9_.-]*["']?[:=]"#)

    /// Token formats with a fixed prefix, on top of `SecretRules`' AWS,
    /// OpenAI-style `sk-` and GitHub `gh?_` shapes.
    static let tokenFormatPatterns: [NSRegularExpression] = [
        regex(#"(?<![A-Za-z0-9])xox[abeprs]-[A-Za-z0-9-]{10,}"#),
        regex(#"(?<![A-Za-z0-9])xapp-[A-Za-z0-9-]{10,}"#),
        regex(#"(?<![A-Za-z0-9])(?:sk|rk)_(?:live|test)_[A-Za-z0-9]{16,}"#),
        regex(#"(?<![A-Za-z0-9])AIza[0-9A-Za-z_-]{35}(?![A-Za-z0-9_-])"#),
        regex(#"(?<![A-Za-z0-9])github_pat_[A-Za-z0-9_]{22,}"#),
        regex(#"(?<![A-Za-z0-9])glpat-[A-Za-z0-9_-]{20,}"#),
        regex(#"(?<![A-Za-z0-9])npm_[A-Za-z0-9]{36}(?![A-Za-z0-9])"#),
        regex(#"(?<![A-Za-z0-9])hf_[A-Za-z0-9]{34,}"#),
        regex(#"(?<![A-Za-z0-9])SG\.[A-Za-z0-9_-]{22}\.[A-Za-z0-9_-]{43}(?![A-Za-z0-9_-])"#),
        regex(#"(?<![0-9])\d{8,10}:AA[A-Za-z0-9_-]{33}(?![A-Za-z0-9_-])"#),
        regex(#"(?<![A-Za-z0-9])SK[0-9a-fA-F]{32}(?![A-Za-z0-9])"#),
        regex(#"hooks\.slack\.com/(?:services|workflows|triggers)/[A-Za-z0-9/_-]{20,}"#),
        regex(#"discord(?:app)?\.com/api/webhooks/\d+/[A-Za-z0-9_-]{20,}"#),
    ]

    /// `scheme://user:PASS@host`.
    private static let urlCredentialPattern = regex(#"\b[A-Za-z][A-Za-z0-9+.-]*://[^\s:/@]+:([^\s@/]+)@"#)

    /// `password: X`, `pwd=X`, `passphrase = "X"`.
    private static let passwordLabelPattern = regex(
        #"(?<!-)\b(password|passwd|passphrase|passcode|pwd|pw)[^\S\n]*[:=][^\S\n]*("[^"\n]+"|'[^'\n]+'|`[^`\n]+`|\S+)"#,
        caseInsensitive: true
    )

    /// `pass: hunter22`. Not `case .pass:` or `ok.pass = x`.
    private static let passLabelPattern = regex(
        #"(?<![-.])\bpass[^\S\n]*[:=][^\S\n]*("[^"\n]+"|'[^'\n]+'|`[^`\n]+`|\S+)"#,
        caseInsensitive: true
    )

    /// `password is X`, `the pw was X`, `the password for the guest wifi is X`.
    private static let passwordIsPattern = regex(
        #"\b(password|passwd|passphrase|passcode|pwd|pw)(?:[^\S\n]+(?:for|to|of|on)(?:[^\S\n]+[A-Za-z0-9'\u2019-]+){1,4}?)?[^\S\n]+(?:is|was)[^\S\n]+("[^"\n]+"|'[^'\n]+'|`[^`\n]+`|\S+)"#,
        caseInsensitive: true
    )

    /// `PIN: 4821`, `pin is 4821`, `PIN number 4821`, `pin code 4821`.
    /// "pin 1000 items" stays (`isCountedNumber`).
    private static let pinPattern = regex(
        #"\bpin(?:[^\S\n]*[:=][^\S\n]*|[^\S\n]+(?:is|was)[^\S\n]+|[^\S\n]+(?:code|number)(?:[^\S\n]*[:=][^\S\n]*|[^\S\n]+(?:is|was)[^\S\n]+|[^\S\n]+))(\d{4,8})\b"#,
        caseInsensitive: true
    )

    /// Words before `pin` that make it a noun: `my pin`, `the gate pin`.
    private static let pinOwnerWords: Set<String> = [
        "my", "your", "our", "the", "door", "gate", "garage", "card", "debit", "atm", "sim", "phone", "new", "old",
    ]

    /// `PIN 4821` with nothing between: group 1 is `pin` as typed.
    private static let barePinPattern = regex(#"\b(pin)[^\S\n]+(\d{4,8})\b"#, caseInsensitive: true)

    /// `verification code: 482913`, `my 2fa code is 4829 13`.
    private static let codeLabelPattern = regex(
        #"\b(?:verification|security|one[- ]time|login|sign[- ]in|2fa|mfa|auth|authentication|confirmation|access|backup|recovery)[^\S\n]+codes?[^\S\n]*(?:[:=]|[^\S\n]is|[^\S\n]was)?[^\S\n]*((?=[A-Za-z]{0,7}\d)[A-Za-z0-9]{2,8}(?:[ -]\d{2,8})?)\b"#,
        caseInsensitive: true
    )

    /// `the code is 482913`, `code: 4829`. Group 1 is the word before
    /// `code`, so `zip code is 94110` can be left alone; "the code was 1500
    /// lines long" stays (`isCountedNumber`).
    private static let bareCodePattern = regex(
        #"(?:\b([A-Za-z]+)[^\S\n]+)?\bcodes?[^\S\n]*(?:[:=]|[^\S\n]is|[^\S\n]was)[^\S\n]*(\d{4,8})\b"#,
        caseInsensitive: true
    )

    /// Codes that aren't secrets.
    private static let notSecretCodeWords: Set<String> = [
        "zip", "postal", "post", "area", "country", "promo", "discount", "coupon", "referral", "source",
        "error", "status", "exit", "return", "response", "http", "product", "tracking", "airport", "dialing",
    ]

    /// `CVC 123`, `cvv: 1234`.
    private static let cvvLabelPattern = regex(#"\b(?:cvv2?|cvc2?)[^\S\n]*[:=]?[^\S\n]*(\d{3,4})\b"#, caseInsensitive: true)

    /// `CSC: 123`, `CID 1234`: group 1 is what separates label and value.
    private static let cscLabelPattern = regex(#"\b(?:csc|cid)([^\S\n]*[:=]?[^\S\n]*)(\d{3,4})\b"#, caseInsensitive: true)

    /// Words that put a CSC or CID next to a card (not `csc` itself).
    private static let cardOnlyWordPattern = regex(
        #"\b(?:card|cvv2?|cvc2?|visa|mastercard|amex|discover|exp|expiry|expires)\b"#,
        caseInsensitive: true
    )

    /// `exp 04/28`, `expires: 4/2028`.
    static let expiryLabelPattern = regex(
        #"\b(?:exp|expiry|expires|expiration)(?:[^\S\n]+date)?[^\S\n]*[:=]?[^\S\n]*((?:0?[1-9]|1[0-2])[^\S\n]?/[^\S\n]?(?:\d{2}|\d{4}))\b"#,
        caseInsensitive: true
    )

    /// Words that put an expiry next to a card.
    private static let cardWordPattern = regex(
        #"\b(?:card|cvv2?|cvc2?|csc|visa|mastercard|amex|discover)\b"#,
        caseInsensitive: true
    )

    /// `OTP: 482913`, `otp is 4829`.
    private static let otpLabelPattern = regex(
        #"\botp[^\S\n]*(?:[:=]|[^\S\n]is|[^\S\n]was)[^\S\n]*([A-Za-z0-9]{4,10})\b"#,
        caseInsensitive: true
    )

    /// `mysql -u root -pHUNTER2` (attached value; bare `-p` prompts instead).
    private static let mysqlAttachedPattern = regex(#"\b(?:mysql|mariadb|mysqldump|mysqladmin)\b[^\n]*?[^\S\n]-p(?!assword)([^\s-]\S*)"#)

    /// `sshpass -p X`.
    private static let sshpassPattern = regex(#"\bsshpass[^\S\n]+-p[^\S\n]*(\S+)"#)

    /// `redis-cli … -a X`.
    private static let redisPattern = regex(#"\bredis-cli\b[^\n]*?[^\S\n]-a[^\S\n]+(\S+)"#)

    /// `curl -u user:PASS`, `curl --user 'user:PASS'`.
    private static let curlUserPattern = regex(#"\bcurl\b[^\n]*?[^\S\n](?:-u|--user)[^\S\n]+['"]?[^\s:'"]+:([^\s'"]+)"#)

    /// `--password X`, `--token=X`.
    private static let secretFlagPattern = regex(
        #"(?:^|[^\S\n])--(?:password|passwd|pass|token|secret|api-key|apikey|api-token|auth-token|access-token|client-secret|private-key)(?:=|[^\S\n]+)("[^"\n]+"|'[^'\n]+'|\S+)"#,
        caseInsensitive: true
    )

    /// `Authorization: Bearer X`.
    private static let bearerPattern = regex(#"\bbearer[^\S\n]+([A-Za-z0-9._~+/=-]{8,})"#, caseInsensitive: true)

    /// `Authorization: Basic X`.
    private static let basicPattern = regex(#"\bbasic[^\S\n]+([A-Za-z0-9._~+/=-]{8,})"#, caseInsensitive: true)

    /// A line about HTTP auth, where `Basic X` is a credential.
    private static let authMentionPattern = regex(
        #"\b(?:auth|authorization|authenticate|authentication|header|credentials?)\b|-H[^\S\n]"#,
        caseInsensitive: true
    )

    /// `KEY_NAME=value`, `github_token: value`, `"apiKey": "value"`.
    private static let secretKeyPattern = regex(
        #"(?<![A-Za-z0-9_.-])["']?([A-Za-z][A-Za-z0-9_.-]*)["']?([^\S\n]*(?:=(?![=>~])|:(?![:=]))[^\S\n]*)("[^"\n]+"|'[^'\n]+'|`[^`\n]+`|[^\s"'`,;=][^\s"'`,;]*)"#
    )

    /// `SENTRY_AUTH_TOKEN`: a shell variable name.
    private static let screamingKeyPattern = wholeLine(#"[A-Z][A-Z0-9_]*"#)

    /// Names and expressions with no digits: `pasteToken`, `Equatable`,
    /// `DefaultInputDeviceMonitor.ObserverToken?`.
    private static let identifierValuePattern = wholeLine(#"[A-Za-z_][A-Za-z_]*([?!]?\.[A-Za-z_][A-Za-z_]*)*[?!]?"#)

    /// Swift attributes and type names with a size: `@unchecked`, `UInt64`.
    private static let codeTypeValuePattern = wholeLine(#"@[A-Za-z]+|[A-Z][A-Za-z]*\d{1,3}[?!]?"#)

    /// Placeholders people write in docs: `your-sentry-token`, `api_key`.
    private static let placeholderNamePattern = wholeLine(#"[a-z]+([-_][a-z]+)+"#)

    /// Card numbers: 4-4-4-4 (with an optional 1–3 digit tail), Amex 4-6-5,
    /// or 13–19 digits in one run, never touching a letter, digit or hyphen
    /// that would make it part of a longer ID (UUIDs, entry IDs).
    static let cardPatterns: [NSRegularExpression] = [
        regex(#"(?<![A-Za-z0-9-])\d{4}[ -]\d{4}[ -]\d{4}[ -]\d{4}[ -]\d{1,3}(?![A-Za-z0-9]|-[A-Za-z0-9])"#),
        regex(#"(?<![A-Za-z0-9-])\d{4}[ -]\d{4}[ -]\d{4}[ -]\d{4}(?![A-Za-z0-9]|-[A-Za-z0-9])"#),
        regex(#"(?<![A-Za-z0-9-])\d{4}[ -]\d{6}[ -]\d{5}(?![A-Za-z0-9]|-[A-Za-z0-9])"#),
        regex(#"(?<![A-Za-z0-9-])\d{13,19}(?![A-Za-z0-9]|-[A-Za-z0-9])"#),
    ]

    /// What follows a card number on the same line: an expiry, then maybe
    /// a CVV. Anchored at the card's end.
    private static let cardTailPattern = regex(
        #"^[ ,;/]+((?:0?[1-9]|1[0-2]) ?/ ?(?:\d{4}|\d{2}))(?:[ ,;]+(\d{3,4}))?(?![\d/])"#
    )

    /// Long runs of the base64 alphabet, judged by `isRandomToken`.
    static let genericTokenPattern = regex(#"(?<![A-Za-z0-9+/_=-])[A-Za-z0-9+/_=-]{32,}(?![A-Za-z0-9+/_=-])"#)

    // MARK: - Regex plumbing

    /// For `wholeLine` patterns.
    static func matchesWhole(_ text: String, _ pattern: NSRegularExpression) -> Bool {
        firstMatch(text, pattern) != nil
    }

    static func firstMatch(_ text: String, _ pattern: NSRegularExpression) -> NSTextCheckingResult? {
        pattern.firstMatch(in: text, range: NSRange(location: 0, length: (text as NSString).length))
    }

    static func enumerateMatches(_ text: String, _ pattern: NSRegularExpression, _ body: (NSTextCheckingResult) -> Void) {
        pattern.enumerateMatches(in: text, range: NSRange(location: 0, length: (text as NSString).length)) { match, _, _ in
            if let match { body(match) }
        }
    }

}
