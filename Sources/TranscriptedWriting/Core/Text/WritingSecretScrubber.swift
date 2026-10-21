import Foundation

/// Scrubs secrets out of Save my writing text before it reaches a day file.
/// Secure input and the password-manager list stop most secrets at the
/// keyboard, but a lot of password typing happens where secure input is off:
/// sudo and ssh prompts in terminals, `read -s`, a web field with "show
/// password" on, OTP and PIN boxes, card forms. Those keystrokes arrive here
/// as ordinary text.
///
/// The text is one entry: lines, one per keyboard segment (Return, Tab and a
/// caret jump each start a segment). Three layers run over it:
///
/// 1. **Line rules.** What a line is, judged from the lines around it: the
///    answer to a password prompt in a terminal, a line that is nothing but a
///    password-shaped token, a one-time code, a card number split over boxes
///    and the expiry and CVV after it. A run of one-character lines (apps
///    that don't move the caret per key, like a terminal with echo off) is
///    judged as the word it spells.
/// 2. **`SecretRules`** for structured secrets (IBAN, SSN, API-key shapes,
///    JWT, PEM). Emails and phone numbers are kept: this is the user's own
///    writing. Its loose generic-token and card rules are off; layer 3 runs
///    stricter ones, because people paste paths, env names and IDs into
///    their writing all the time.
/// 3. **Inline rules.** Values next to a label (`password: …`, `API_KEY=…`,
///    `--token …`, `Bearer …`, `user:pass@` in a URL) and token formats
///    `SecretRules` doesn't know.
///
/// Context lines (`precedingLines`) are only read, never returned. Pure and
/// deterministic, Foundation only; nothing leaves the process. Not part of
/// Tilde.
public enum WritingSecretScrubber {
    public enum Kind: String, Equatable, Sendable, CaseIterable {
        /// A typed password or passphrase.
        case password
        /// A one-time code, PIN, CVV or recovery code.
        case code
        /// A payment card number, or the expiry typed right after one.
        case card
        /// The value after a secret-looking label: `KEY=…`, `--token …`, `Bearer …`.
        case secret
        /// A recognized API token format.
        case apiKey = "api-key"
        case jwt
        case pem
        case iban
        case ssn
    }

    public struct Result: Equatable, Sendable {
        public let clean: String
        /// One per redaction this call made, in text order.
        public let kinds: [Kind]
        /// Nothing but redaction tokens, whitespace and punctuation is left.
        public let isOnlyRedactions: Bool
    }

    /// Bumped whenever the rules change in a way worth re-running over files
    /// already on disk.
    public static let rulesVersion = 4

    private static let tokenPattern = regex(#"\x{27E8}redacted:([a-z-]+)\x{27E9}"#)
    static let tokenOpen = "\u{27E8}redacted:"
    private static let tokenClose = "\u{27E9}"

    /// `⟨redacted:<kind>⟩`, the same shape `SecretRules` writes.
    public static func token(for kind: Kind) -> String {
        tokenOpen + kind.rawValue + tokenClose
    }

    public static func scrub(
        _ text: String,
        appBundleIdentifier: String,
        precedingLines: [String] = []
    ) -> Result {
        guard !text.isEmpty else { return Result(clean: text, kinds: [], isOnlyRedactions: false) }
        let existing = WritingScrubberTokenIdentity(text)
        let terminal = terminalKind(appBundleIdentifier)
        let afterLines = applyLineRules(
            existing.markedText,
            terminal: terminal,
            inBrowser: browserBundleIdentifiers.contains(appBundleIdentifier.lowercased()),
            precedingLines: precedingLines, restoreOldTokens: existing.originalText
        )
        // Structured shapes first, so a JWT or PEM is one token rather than
        // pieces the generic-token rule would take.
        let afterStructured = SecretRules.scrub(afterLines, config: structuredOnly).clean
        let clean = applyInlineRules(afterStructured)
        return existing.result(from: clean)
    }

    /// `SecretRules`' structured shapes only. Emails and phones are the
    /// user's own writing; its generic-token and card rules are replaced by
    /// the stricter `genericTokenPattern` and `cardPatterns` here.
    private static let structuredOnly = SecretRules.ScrubConfig(
        scrubEmails: false,
        scrubPhones: false,
        scrubGenericTokens: false,
        scrubCardNumbers: false
    )

    // MARK: - Terminals

    private enum TerminalKind {
        case none
        /// A terminal emulator: every line is a shell line.
        case terminal
        /// An editor with a built-in terminal: a line may be code instead.
        case editor
    }

    private static let terminalBundleIdentifiers: Set<String> = [
        "com.apple.terminal",
        "com.googlecode.iterm2",
        "dev.warp.warp-stable",
        "dev.warp.warp",
        "dev.warp.warp-preview",
        "com.mitchellh.ghostty",
        "net.kovidgoyal.kitty",
        "org.alacritty",
        "io.alacritty",
        "com.github.wez.wezterm",
        "co.zeit.hyper",
        "org.tabby",
        "com.termius-dmg.mac",
        "com.raphaelamorim.rio",
        "dev.commandline.waveterm",
    ]

    private static let editorBundleIdentifiers: Set<String> = [
        "com.microsoft.vscode",
        "com.microsoft.vscodeinsiders",
        "com.visualstudio.code.oss",
        "com.vscodium",
        "com.todesktop.230313mzl4w4u92",
        "com.exafunction.windsurf",
        "dev.zed.zed",
        "dev.zed.zed-preview",
        "com.google.android.studio",
        "com.panic.nova",
    ]

    /// Where "show password" fields are, and also address and search bars
    /// full of product names (`macOS26`, `M2Ultra`), so a word with a number
    /// on the end counts only when it's built on a common password word or
    /// follows a `password:` line.
    private static let browserBundleIdentifiers: Set<String> = [
        "com.google.chrome", "com.google.chrome.beta", "com.google.chrome.canary", "com.apple.safari",
        "com.apple.safaritechnologypreview", "org.mozilla.firefox", "org.mozilla.firefoxdeveloperedition",
        "com.microsoft.edgemac", "com.brave.browser", "company.thebrowser.browser", "company.thebrowser.dia",
        "com.operasoftware.opera", "com.vivaldi.vivaldi", "app.zen-browser.zen", "com.kagi.kagimacos",
        "org.chromium.chromium", "ai.perplexity.comet", "com.openai.atlas",
    ]

    /// Terminals, and editors with a built-in terminal (VS Code, Cursor, Zed,
    /// JetBrains IDEs). Exact bundle IDs, case-insensitive, except the
    /// `com.jetbrains.` prefix every JetBrains IDE shares.
    public static func isTerminalLike(_ bundleIdentifier: String) -> Bool {
        terminalKind(bundleIdentifier) != .none
    }

    private static func terminalKind(_ bundleIdentifier: String) -> TerminalKind {
        let id = bundleIdentifier.lowercased()
        if terminalBundleIdentifiers.contains(id) { return .terminal }
        if editorBundleIdentifiers.contains(id) || id.hasPrefix("com.jetbrains.") { return .editor }
        return .none
    }

    // MARK: - Layer 1: line rules

    /// One line, or a run of one-character lines read as the word it spells.
    private struct Unit {
        let lines: Range<Int>
        let text: String
        let isContext: Bool
    }

    private static let minimumCharacterRun = 3

    private static func units(of lines: [String], entryStart: Int) -> [Unit] {
        var units: [Unit] = []
        var index = 0
        while index < lines.count {
            let isContext = index < entryStart
            if isSingleCharacter(lines[index]) {
                var end = index + 1
                while end < lines.count, (end < entryStart) == isContext, isSingleCharacter(lines[end]) {
                    end += 1
                }
                if end - index >= minimumCharacterRun {
                    let word = lines[index..<end].map { $0.trimmingCharacters(in: .whitespaces) }.joined()
                    units.append(Unit(lines: index..<end, text: word, isContext: isContext))
                    index = end
                    continue
                }
            }
            units.append(Unit(lines: index..<(index + 1), text: lines[index], isContext: isContext))
            index += 1
        }
        return units
    }

    private static func isSingleCharacter(_ line: String) -> Bool {
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        return trimmed.count == 1
    }

    private struct PromptState {
        var answersLeft: Int
        let looseAnswers: Int
        var answered: Int
        let allowsSpaces: Bool
        /// The first answer, so typing it again (a confirmation) counts.
        var firstAnswer: String?

        mutating func consume(_ answer: String) -> PromptState? {
            answersLeft -= 1
            answered += 1
            if firstAnswer == nil { firstAnswer = answer }
            return answersLeft > 0 ? self : nil
        }
    }

    private static let cardFollowUpUnits = 4

    private static func applyLineRules(
        _ text: String,
        terminal: TerminalKind,
        inBrowser: Bool,
        precedingLines: [String], restoreOldTokens: (String) -> String
    ) -> String {
        let context = precedingLines.flatMap { $0.split(separator: "\n", omittingEmptySubsequences: false).map(String.init) }
        let entryLines = text.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
        let allLines = context + entryLines
        let units = units(of: context + entryLines.map(restoreOldTokens), entryStart: context.count)

        var redactions: [Int: Kind] = [:]
        /// Units swallowed into a redaction that starts at an earlier unit.
        var absorbed: Set<Int> = []
        var prompt: PromptState?
        var cardFollowUpsLeft = 0
        var previousMentionsCode = false
        var inCodeList = false
        var previousAsksPassword = false

        var index = 0
        while index < units.count {
            let unit = units[index]
            let trimmed = unit.text.trimmingCharacters(in: .whitespaces)
            defer { index += 1 }
            guard !trimmed.isEmpty else { continue }
            // Context units are never written out, so marking one is harmless.
            let mark: (Kind) -> Void = { kind in redactions[index] = kind }

            // Answers to a terminal password prompt.
            if var state = prompt {
                // An answer an earlier pass already redacted (a day file
                // being rescrubbed) used up that answer, so running the
                // rules again over their own output changes nothing.
                if WritingScrubberTokenIdentity.isPasswordToken(trimmed) {
                    prompt = state.consume(trimmed)
                    previousMentionsCode = false
                    continue
                }
                if isPromptAnswer(trimmed, state: state, terminal: terminal) {
                    mark(.password)
                    prompt = state.consume(trimmed)
                    previousMentionsCode = false
                    continue
                }
                prompt = nil
            }
            if terminal != .none, let asked = promptingCommand(trimmed) {
                prompt = PromptState(
                    answersLeft: asked.answers,
                    looseAnswers: asked.looseAnswers,
                    answered: 0,
                    allowsSpaces: asked.passphrase && terminal == .terminal
                )
                previousMentionsCode = mentionsCode(trimmed)
                continue
            }

            // A code over several boxes of 2–4 digits, when that's the
            // whole entry (`482`, `913`).
            if !unit.isContext, let end = splitCodeEnd(units, from: index) {
                mark(.code)
                for absorbedIndex in (index + 1)...end { absorbed.insert(absorbedIndex) }
                index = end
                previousMentionsCode = false
                continue
            }
            // A card number split over boxes, one group per line.
            if !unit.isContext, let end = splitCardEnd(units, from: index) {
                mark(.card)
                for absorbedIndex in (index + 1)...end { absorbed.insert(absorbedIndex) }
                index = end
                cardFollowUpsLeft = cardFollowUpUnits
                previousMentionsCode = false
                continue
            }

            // Expiry and CVV right after a card, also month and year typed
            // in boxes of their own (`12`, `28`).
            if cardFollowUpsLeft > 0 {
                cardFollowUpsLeft -= 1
                if isCVV(trimmed) {
                    mark(.code)
                    continue
                }
                if isExpiry(trimmed) || (trimmed.count <= 2 && trimmed.allSatisfy(isDigit))
                    || firstMatch(trimmed, expiryLabelPattern) != nil {
                    mark(.card)
                    continue
                }
            }
            if lineHoldsCard(trimmed) {
                cardFollowUpsLeft = cardFollowUpUnits
                previousMentionsCode = mentionsCode(trimmed)
                continue
            }
            if isCardDigits(trimmed) {
                // A card typed one digit per line.
                mark(.card)
                cardFollowUpsLeft = cardFollowUpUnits
                previousMentionsCode = false
                continue
            }

            if isOneTimeCode(trimmed) || (previousMentionsCode && isShortCode(trimmed)) {
                mark(.code)
                previousMentionsCode = false
                continue
            }
            // Under "backup codes:" and the like, each code on its own line
            // (`ABCD-1234`) is a code even where it would read as a ticket ID.
            if inCodeList, isListedCode(trimmed) {
                mark(.code)
                continue
            }
            inCodeList = firstMatch(trimmed, codeListPattern) != nil
            // `wifi password:` on one line, the password alone on the next.
            if previousAsksPassword, !trimmed.contains(where: \.isWhitespace), isLikelySecretValue(trimmed) {
                mark(.password)
                previousAsksPassword = false
                previousMentionsCode = false
                continue
            }
            previousAsksPassword = firstMatch(trimmed, asksPasswordPattern) != nil
            // An editor line is code, not a field someone typed a password into.
            if terminal != .editor,
               let kind = standalonePasswordKind(
                   trimmed,
                   app: terminal == .terminal ? .terminal : inBrowser ? .browser : .other
               ) {
                mark(kind)
                previousMentionsCode = false
                continue
            }
            previousMentionsCode = mentionsCode(trimmed)
        }

        guard !redactions.isEmpty else { return text }
        var output: [String] = []
        for (unitIndex, unit) in units.enumerated() where !unit.isContext {
            if let kind = redactions[unitIndex] {
                output.append(leadingWhitespace(of: allLines[unit.lines.lowerBound]) + token(for: kind))
            } else if absorbed.contains(unitIndex) {
                continue
            } else {
                output.append(contentsOf: allLines[unit.lines])
            }
        }
        return output.joined(separator: "\n")
    }

    private static func leadingWhitespace(of line: String) -> String {
        String(line.prefix { $0 == " " || $0 == "\t" })
    }

    // MARK: Prompt answers

    private static func isPromptAnswer(_ line: String, state: PromptState, terminal: TerminalKind) -> Bool {
        // Under 4 characters also covers `y`, `n`, `yes`, `no`, `q`.
        guard line.count >= 4 else { return false }
        guard !line.hasPrefix(tokenOpen) else { return false }
        // The same answer again: a new password or passphrase confirmed.
        if let first = state.firstAnswer, line == first { return true }
        let firstWord = line.split(whereSeparator: \.isWhitespace).first.map(String.init) ?? line
        if isNextCommand(line, firstWord: firstWord, answered: state.answered, looseAnswers: state.looseAnswers) { return false }
        if line.contains(where: \.isWhitespace) {
            // Only a passphrase prompt's first answer may have spaces.
            return state.allowsSpaces && state.answered == 0
        }
        if terminal == .editor, looksLikeCode(line) { return false }
        // Past the answers the prompt surely asks for (sudo's retry after a
        // wrong password), the line has to look like a password by itself,
        // or be a near miss of the first answer (`sunshien`, then
        // `sunshine`): `pytest` or `lazygit` after sudo had cached
        // credentials stays.
        if state.answered >= state.looseAnswers {
            if let first = state.firstAnswer, isRetypeOf(first, line) { return true }
            return standalonePasswordKind(line, app: .terminal) != nil
        }
        return true
    }

    /// `retry` is `first` typed again with a slip: at most 2 edits apart.
    private static func isRetypeOf(_ first: String, _ retry: String) -> Bool {
        let a = Array(first), b = Array(retry)
        guard a.count <= 64, b.count <= 64, abs(a.count - b.count) <= 2, !first.hasPrefix(tokenOpen) else {
            return false
        }
        guard !a.isEmpty, !b.isEmpty else { return false }
        var previous = Array(0...b.count)
        for i in 1...a.count {
            var current = [i] + Array(repeating: 0, count: b.count)
            for j in 1...b.count {
                let cost = a[i - 1] == b[j - 1] ? 0 : 1
                current[j] = min(previous[j] + 1, current[j - 1] + 1, previous[j - 1] + cost)
            }
            previous = current
        }
        return previous[b.count] <= 2
    }

    static func isPathLike(_ word: String) -> Bool {
        word.hasPrefix("/") || word.hasPrefix("./") || word.hasPrefix("../") || word.hasPrefix("~")
    }

    private static func looksLikeCode(_ line: String) -> Bool {
        line.hasSuffix(";") || line.hasSuffix("{") || line.hasSuffix("}")
            || (line.contains("(") && line.hasSuffix(")"))
    }

    // MARK: Codes and cards

    private static func isOneTimeCode(_ line: String) -> Bool {
        matchesWhole(line, oneTimeCodePattern)
    }

    private static func isShortCode(_ line: String) -> Bool {
        matchesWhole(line, shortCodePattern)
    }

    private static func isCVV(_ line: String) -> Bool {
        matchesWhole(line, cvvPattern)
    }

    private static func isExpiry(_ line: String) -> Bool {
        matchesWhole(line, expiryPattern)
    }

    private static func isListedCode(_ line: String) -> Bool {
        (6...24).contains(line.count)
            && !line.contains(where: \.isWhitespace)
            && line.contains(where: isDigit)
            && line.allSatisfy { $0.isLetter || $0.isNumber || $0 == "-" }
    }

    /// A redaction token never mentions a code: `⟨redacted:code⟩` has
    /// `code` in it, and a second pass would read the number after it as one.
    private static func mentionsCode(_ line: String) -> Bool {
        let range = NSRange(location: 0, length: (line as NSString).length)
        let words = tokenPattern.stringByReplacingMatches(in: line, range: range, withTemplate: " ")
        return firstMatch(words, codeKeywordPattern) != nil
    }

    private static func isCardDigits(_ line: String) -> Bool {
        let digits = line.filter { $0 != " " && $0 != "-" }
        guard digits.allSatisfy(isDigit), (13...19).contains(digits.count) else { return false }
        return isCardNumber(digits)
    }

    static func lineHoldsCard(_ line: String) -> Bool {
        cardPatterns.contains { pattern in
            var found = false
            enumerateMatches(line, pattern) { match in
                if let range = Range(match.range, in: line), isCardNumber(String(line[range])) { found = true }
            }
            return found
        }
    }

    /// Luhn-valid, 13–19 digits, starting 2–6 like every major network.
    static func isCardNumber(_ raw: String) -> Bool {
        let digits = raw.filter(isDigit)
        guard (13...19).contains(digits.count), let first = digits.first, ("2"..."6").contains(first) else { return false }
        return isValidLuhn(digits)
    }

    /// The last unit of a card number typed over several boxes starting at
    /// `start`, each box its own line of digits. Longest Luhn-valid run of
    /// 2+ boxes totalling 13–19 digits.
    private static func splitCardEnd(_ units: [Unit], from start: Int) -> Int? {
        var digits = ""
        var best: Int?
        var index = start
        while index < units.count, !units[index].isContext {
            let box = units[index].text.trimmingCharacters(in: .whitespaces)
            guard !box.isEmpty, box.count <= 8, box.allSatisfy(isDigit) else { break }
            digits += box
            guard digits.count <= 19 else { break }
            if index > start, digits.count >= 13, isCardNumber(digits) { best = index }
            index += 1
        }
        return best
    }

    /// The last unit of a code typed over 2+ boxes of 2–4 digits that make
    /// up the rest of the entry and join to 6–8 digits. Only a whole entry,
    /// so two numbers in a chat (`100`, `200`) mid-conversation stay.
    private static func splitCodeEnd(_ units: [Unit], from start: Int) -> Int? {
        let rest = units[start...].filter { !$0.text.trimmingCharacters(in: .whitespaces).isEmpty }
        guard rest.count >= 2, start == units.firstIndex(where: { !$0.isContext }),
              rest.allSatisfy({ box in
                  let digits = box.text.trimmingCharacters(in: .whitespaces)
                  return !box.isContext && (2...4).contains(digits.count) && digits.allSatisfy(isDigit)
              }) else { return nil }
        let total = rest.reduce(0) { $0 + $1.text.trimmingCharacters(in: .whitespaces).count }
        return (6...8).contains(total) ? units.count - 1 : nil
    }

    static func isDigit(_ character: Character) -> Bool {
        character.isASCII && character.isNumber
    }

    private static func isValidLuhn(_ digits: String) -> Bool {
        var sum = 0
        var alternate = false
        for character in digits.reversed() {
            guard var value = character.wholeNumberValue else { return false }
            if alternate {
                value *= 2
                if value > 9 { value -= 9 }
            }
            sum += value
            alternate.toggle()
        }
        return sum % 10 == 0
    }

    // MARK: Standalone passwords

    static let strongSymbols = Set("!@#$%^&*+=?<>|~")
    private static let trailingPunctuation = CharacterSet(charactersIn: ".,!?;:…)\"'\u{2019}\u{201D}")
    private static let leadingPunctuation = CharacterSet(charactersIn: "(\"'\u{2018}\u{201C}")

    /// Where a one-token line was typed, for how sure the standalone rule
    /// has to be.
    private enum StandaloneApp {
        /// Every line is a shell line; `Tigers2024` is an answer to something.
        case terminal
        /// A "show password" field is likely, but so is an address bar.
        case browser
        /// Chat, mail, notes: product names (`M2Ultra`, `x86_64`) are
        /// everyday words, so only a random-looking token counts.
        case other
    }

    /// Letter-digit switches a token needs outside terminals and browsers
    /// (`Tr0ub4dor`, `8f3Kd9Lq`), unless it has a strong symbol inside or is
    /// built on a common password word. `M2Ultra` and `GPT-4o` have fewer.
    private static let otherAppLetterDigitSwitches = 3

    /// A line that is a single password-shaped token. Mixed letters and
    /// digits, or letters with a strong symbol inside the word. Upper-case
    /// letters and digits only reads as a code (`B7X9QK`). Things that are
    /// usually not secrets are left alone: URLs, emails, hosts and file
    /// names, paths, flags, handles, hashtags, versions, dates and times,
    /// ticket IDs, amounts, units, git hashes.
    private static func standalonePasswordKind(_ line: String, app: StandaloneApp) -> Kind? {
        guard (6...64).contains(line.count), !line.contains(where: \.isWhitespace) else { return nil }
        guard !line.hasPrefix(tokenOpen), !isStructuredSecret(line) else { return nil }
        let dollarValue = isDollarValue(line)
        if let first = line.first, !dollarValue, "@#/~-$€£:\\`<[{".contains(first) || line.hasPrefix("./") || line.hasPrefix("../") {
            return nil
        }
        if line.contains("://") || line.lowercased().hasPrefix("www.") || line.contains("%") { return nil }
        // Paths, Markdown and code: `docs/a-1.md`, `**Area**`, `task?.cancel()`.
        if line.contains(where: { "/()[]{}*`".contains($0) }) || line.contains("?.") || line.contains("!.") {
            return nil
        }
        // `KEY=value` and `label:value`: the inline rules redact just the value.
        if firstMatch(line, labelledLinePattern) != nil { return nil }
        let unquoted = line.trimmingCharacters(in: CharacterSet(charactersIn: "\"',;."))
        if let first = unquoted.first, !dollarValue, "@#/~-$€£:\\`<[{".contains(first) { return nil }
        for pattern in notSecretPatterns where matchesWhole(line, pattern) || matchesWhole(unquoted, pattern) {
            return nil
        }

        let core = line.trimmingCharacters(in: trailingPunctuation).trimmingCharacters(in: leadingPunctuation)
        guard core.count >= 6 else { return nil }
        var hasLetter = false, hasDigit = false, hasLower = false, hasStrongSymbolInside = false
        let characters = Array(core)
        for (offset, character) in characters.enumerated() {
            if character.isLetter {
                hasLetter = true
                if character.isLowercase { hasLower = true }
            } else if character.isNumber {
                hasDigit = true
            } else if strongSymbols.contains(character), offset > 0, offset < characters.count - 1,
                      characters[offset - 1].isLetter || characters[offset - 1].isNumber,
                      characters[offset + 1].isLetter || characters[offset + 1].isNumber {
                // Between two letters or digits (`P@ss`), not `count++`.
                hasStrongSymbolInside = true
            }
        }
        guard hasLetter, hasDigit || hasStrongSymbolInside else { return nil }
        if !hasStrongSymbolInside, matchesWhole(core, wordWithNumberPattern) {
            let stem = core.prefix { $0.isLetter }.lowercased()
            // In a terminal a versioned tool (`python3`, `pip3`) is a command.
            if knownShellWords.contains(stem) || versionedToolStems.contains(stem) { return nil }
            if app != .terminal, !commonPasswordStems.contains(stem) { return nil }
        } else if app == .other, !hasStrongSymbolInside,
                  letterDigitSwitches(core) < otherAppLetterDigitSwitches, !isLeetCommonPassword(core) {
            return nil
        }
        if !hasLower, !hasStrongSymbolInside, core.count <= 12, core.allSatisfy({ $0.isLetter || $0.isNumber }) {
            return .code
        }
        return .password
    }

    /// A common password word spelled with digits for letters: `Passw0rd`,
    /// `l3tmein`, `hunt3r1`. Trailing digits are dropped first.
    static func isLeetCommonPassword(_ token: String) -> Bool {
        let body = String(token.reversed().drop(while: isDigit).reversed())
        guard body.contains(where: isDigit) || body.contains(where: { "@$".contains($0) }) else { return false }
        // `1` stands for `i` or `l`.
        return ["i", "l"].contains { (one: Character) -> Bool in
            let leet: [Character: Character] = ["0": "o", "1": one, "3": "e", "4": "a", "5": "s", "7": "t", "@": "a", "$": "s"]
            let decoded = String(body.map { leet[$0] ?? $0 }).lowercased()
            guard decoded.allSatisfy(\.isLetter) else { return false }
            return commonPasswordStems.contains(decoded)
                || commonPasswordStems.contains { $0.count >= 5 && decoded.hasPrefix($0) }
        }
    }

    /// How often `text` goes from a letter to a digit or back.
    private static func letterDigitSwitches(_ text: String) -> Int {
        var switches = 0
        var previous: Character?
        for character in text {
            if let previous, (previous.isLetter && isDigit(character)) || (isDigit(previous) && character.isLetter) {
                switches += 1
            }
            previous = character
        }
        return switches
    }

    private static func isStructuredSecret(_ line: String) -> Bool {
        if !SecretRules.scrub(line, config: structuredOnly).findings.isEmpty { return true }
        if lineHoldsCard(line) { return true }
        if let match = firstMatch(line, genericTokenPattern), let range = Range(match.range, in: line),
           isRandomToken(String(line[range])) {
            return true
        }
        return tokenFormatPatterns.contains { firstMatch(line, $0) != nil }
    }

    /// A 4–5 digit number followed by what it counts ("1500 lines", "1000
    /// items") is a quantity, not a code. 6–8 digits are always a code.
    static func isCountedNumber(_ match: NSTextCheckingResult, group: Int, in text: String) -> Bool {
        let range = match.range(at: group)
        guard range.location != NSNotFound, range.length <= 5 else { return false }
        let after = (text as NSString).substring(from: range.location + range.length)
        let next = after.drop { $0 == " " || $0 == "\t" }.prefix { $0.isLetter }.lowercased()
        return countNouns.contains(next)
    }

    private static let countNouns: Set<String> = [
        "lines", "items", "files", "users", "people", "rows", "words", "times", "tests", "bugs", "issues",
        "dollars", "bucks", "miles", "steps", "points", "records", "errors", "calls", "requests", "ms",
        "seconds", "minutes", "hours", "days", "weeks", "months", "years", "pages", "commits", "tickets",
        "messages", "emails", "units", "pieces", "characters", "chars", "bytes", "kb", "mb", "gb", "cards",
        "customers", "downloads", "installs", "views", "stars", "votes", "copies", "orders", "tasks",
    ]

    /// The line of `text` that holds `range`.
    static func lineContaining(_ range: NSRange, in text: String) -> String {
        (text as NSString).substring(with: (text as NSString).lineRange(for: range))
    }

    /// Whether `range` sits in a URL's path: the run of non-space text
    /// before it has `://` or starts `www.`. A path or ID in a link is an
    /// address, not a secret; links whose path is the secret (webhooks) are
    /// in `tokenFormatPatterns`, and `?token=` values in the key rule.
    static func isInsideURL(_ range: NSRange, in text: String) -> Bool {
        let before = (text as NSString).substring(to: range.location)
        let word = before.split(whereSeparator: \.isWhitespace).last.map(String.init) ?? ""
        guard let last = before.last, !last.isWhitespace else { return false }
        return word.contains("://") || word.lowercased().hasPrefix("www.")
    }

    /// A long token that reads as random rather than as a path or a name:
    /// upper and lower case, 4+ digits woven in among letters (paths and
    /// identifiers carry a number or two at an edge, if any), and high
    /// entropy. SCREAMING_SNAKE names and lower-case hex fail the case test.
    static func isRandomToken(_ token: String) -> Bool {
        var upper = 0, lower = 0, digits = 0, weave = 0
        var previous: Character?
        for character in token {
            if character.isUppercase { upper += 1 } else if character.isLowercase { lower += 1 } else if isDigit(character) { digits += 1 }
            if let previous, (previous.isLetter && isDigit(character)) || (isDigit(previous) && character.isLetter) {
                weave += 1
            }
            previous = character
        }
        guard upper >= 2, lower >= 2, digits >= 4, weave >= 4 else { return false }
        return shannonEntropy(token) >= 3.5
    }

    private static func shannonEntropy(_ text: String) -> Double {
        var counts: [Character: Int] = [:]
        for character in text { counts[character, default: 0] += 1 }
        let total = Double(text.count)
        return counts.values.reduce(0) { sum, count in
            let probability = Double(count) / total
            return sum - probability * log2(probability)
        }
    }

}
