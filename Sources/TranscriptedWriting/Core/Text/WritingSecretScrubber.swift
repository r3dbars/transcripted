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
    public static let rulesVersion = 2

    private static let tokenOpen = "\u{27E8}redacted:"
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
        let terminal = terminalKind(appBundleIdentifier)
        let afterLines = applyLineRules(
            text,
            terminal: terminal,
            inBrowser: browserBundleIdentifiers.contains(appBundleIdentifier.lowercased()),
            precedingLines: precedingLines
        )
        // Structured shapes first, so a JWT or PEM is one token rather than
        // pieces the generic-token rule would take.
        let afterStructured = SecretRules.scrub(afterLines, config: structuredOnly).clean
        let clean = applyInlineRules(afterStructured)
        let kinds = newTokens(in: clean, comparedWith: text)
        return Result(clean: clean, kinds: kinds, isOnlyRedactions: onlyTokensLeft(clean))
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
        /// Words of a brew/make/script line: running one isn't an answer.
        let commandWords: Set<String>
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
        precedingLines: [String]
    ) -> String {
        let context = precedingLines.flatMap { $0.split(separator: "\n", omittingEmptySubsequences: false).map(String.init) }
        let entryLines = text.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
        let allLines = context + entryLines
        let units = units(of: allLines, entryStart: context.count)

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
                if trimmed == token(for: .password) {
                    prompt = state.consume(trimmed)
                    previousMentionsCode = false
                    continue
                }
                // The tool just installed (`commandWords`); the prompt may still come.
                if state.commandWords.contains(trimmed.lowercased()) { continue }
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
                    allowsSpaces: asked.passphrase && terminal == .terminal,
                    commandWords: commandWords(trimmed)
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
        if knownShellWords.contains(firstWord.lowercased()) || isPathLike(firstWord) { return false }
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

    private static func isPathLike(_ word: String) -> Bool {
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

    private static func lineHoldsCard(_ line: String) -> Bool {
        cardPatterns.contains { pattern in
            var found = false
            enumerateMatches(line, pattern) { match in
                if let range = Range(match.range, in: line), isCardNumber(String(line[range])) { found = true }
            }
            return found
        }
    }

    /// Luhn-valid, 13–19 digits, starting 2–6 like every major network.
    private static func isCardNumber(_ raw: String) -> Bool {
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

    private static func isDigit(_ character: Character) -> Bool {
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

    private static let strongSymbols = Set("!@#$%^&*+=?<>|~")
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
    private static func isLeetCommonPassword(_ token: String) -> Bool {
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
    private static func isCountedNumber(_ match: NSTextCheckingResult, group: Int, in text: String) -> Bool {
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
    private static func lineContaining(_ range: NSRange, in text: String) -> String {
        (text as NSString).substring(with: (text as NSString).lineRange(for: range))
    }

    /// Whether `range` sits in a URL's path: the run of non-space text
    /// before it has `://` or starts `www.`. A path or ID in a link is an
    /// address, not a secret; links whose path is the secret (webhooks) are
    /// in `tokenFormatPatterns`, and `?token=` values in the key rule.
    private static func isInsideURL(_ range: NSRange, in text: String) -> Bool {
        let before = (text as NSString).substring(to: range.location)
        let word = before.split(whereSeparator: \.isWhitespace).last.map(String.init) ?? ""
        guard let last = before.last, !last.isWhitespace else { return false }
        return word.contains("://") || word.lowercased().hasPrefix("www.")
    }

    /// A long token that reads as random rather than as a path or a name:
    /// upper and lower case, 4+ digits woven in among letters (paths and
    /// identifiers carry a number or two at an edge, if any), and high
    /// entropy. SCREAMING_SNAKE names and lower-case hex fail the case test.
    private static func isRandomToken(_ token: String) -> Bool {
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

    // MARK: - Layer 2: inline rules

    private struct Candidate {
        let range: Range<String.Index>
        let kind: Kind
        let priority: Int
    }

    private static func applyInlineRules(_ text: String) -> String {
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
        for candidate in candidates where candidate.range.lowerBound >= cursor {
            output += text[cursor..<candidate.range.lowerBound]
            output += token(for: candidate.kind)
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

    private static func substring(_ match: NSTextCheckingResult, group: Int, in text: String) -> String? {
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

    private static func isLikelySecretValue(_ value: String) -> Bool {
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

    private static let oneTimeCodePattern = wholeLine(#"\d{6,8}|\d{3}[ -]\d{3}|\d{4}[ -]\d{4}"#)
    private static let shortCodePattern = wholeLine(#"\d{4,5}"#)
    private static let cvvPattern = wholeLine(#"\d{3,4}"#)
    private static let expiryPattern = wholeLine(#"(0?[1-9]|1[0-2]) ?/ ?(\d{4}|\d{2})"#)
    /// A line before a 4–5 digit line that makes it a code ("here's the
    /// code", "PIN?"). Lists of codes need `codeListPattern`.
    private static let codeKeywordPattern = regex(
        #"\b(codes?|pin|otp|passcode|verification|verify|2fa|mfa|cvv|cvc|csc)\b"#,
        caseInsensitive: true
    )

    /// A line that heads a list of recovery codes.
    private static let codeListPattern = regex(
        #"\b(?:backup|recovery|one[- ]time|2fa|mfa|emergency)[^\S\n]+codes\b"#,
        caseInsensitive: true
    )

    /// Lines that look like a password by character mix but are ordinary.
    private static let notSecretPatterns: [NSRegularExpression] = [
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
    private static let versionedToolStems: Set<String> = [
        "python", "pip", "php", "ruby", "node", "gcc", "clang", "java", "perl", "lua", "llvm", "openssl",
        "postgres", "psql", "mysql", "redis", "http", "ipv", "utf", "md", "sha", "base", "vim", "emacs",
        "swift", "kotlin", "scala", "dotnet", "net", "ssh", "tls", "ssl", "gpt", "claude", "llama", "qwen",
    ]

    /// A line ending in a password label, with the value on the next line.
    /// Not `wifi:`, which is usually followed by the network's name.
    private static let asksPasswordPattern = regex(
        #"\b(?:password|passwd|passcode|passphrase|pw|pin)[^\S\n]*:[^\S\n]*$"#,
        caseInsensitive: true
    )

    /// The words people build weak passwords from. `hunter22` and
    /// `Password123` count everywhere, not only in browsers.
    private static let commonPasswordStems: Set<String> = [
        "password", "passw", "pass", "pwd", "qwerty", "qwertyuiop", "asdf", "asdfgh", "zxcvbn", "letmein",
        "welcome", "admin", "administrator", "root", "hunter", "dragon", "monkey", "iloveyou", "abc", "abcd",
        "abcdef", "secret", "master", "login", "football", "baseball", "sunshine", "shadow", "princess",
        "superman", "batman", "trustno", "changeme", "default", "test", "guest", "user", "p", "pw",
    ]

    /// A word with a number on the end: `Python3`, `macOS26`, `hunter22`.
    private static let wordWithNumberPattern = wholeLine(#"[A-Za-z]{2,}\d{1,4}"#)

    /// A line that starts `identifier=` or `identifier:`.
    private static let labelledLinePattern = regex(#"^["']?[A-Za-z_][A-Za-z0-9_.-]*["']?[:=]"#)

    /// Token formats with a fixed prefix, on top of `SecretRules`' AWS,
    /// OpenAI-style `sk-` and GitHub `gh?_` shapes.
    private static let tokenFormatPatterns: [NSRegularExpression] = [
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
    private static let expiryLabelPattern = regex(
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
    private static let cardPatterns: [NSRegularExpression] = [
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
    private static let genericTokenPattern = regex(#"(?<![A-Za-z0-9+/_=-])[A-Za-z0-9+/_=-]{32,}(?![A-Za-z0-9+/_=-])"#)

    // MARK: - Regex plumbing

    /// For `wholeLine` patterns.
    static func matchesWhole(_ text: String, _ pattern: NSRegularExpression) -> Bool {
        firstMatch(text, pattern) != nil
    }

    static func firstMatch(_ text: String, _ pattern: NSRegularExpression) -> NSTextCheckingResult? {
        pattern.firstMatch(in: text, range: NSRange(location: 0, length: (text as NSString).length))
    }

    private static func enumerateMatches(_ text: String, _ pattern: NSRegularExpression, _ body: (NSTextCheckingResult) -> Void) {
        pattern.enumerateMatches(in: text, range: NSRange(location: 0, length: (text as NSString).length)) { match, _, _ in
            if let match { body(match) }
        }
    }

    // MARK: - Result bookkeeping

    private static let tokenPattern = regex(#"\x{27E8}redacted:([a-z-]+)\x{27E9}"#)

    private static func tokens(in text: String) -> [Kind] {
        var kinds: [Kind] = []
        enumerateMatches(text, tokenPattern) { match in
            if let raw = substring(match, group: 1, in: text) {
                kinds.append(Kind(rawValue: raw) ?? .secret)
            }
        }
        return kinds
    }

    /// Tokens in `clean` that weren't already in `original`: re-scrubbing a
    /// day file that already has tokens doesn't count them again.
    private static func newTokens(in clean: String, comparedWith original: String) -> [Kind] {
        let after = tokens(in: clean)
        var before = tokens(in: original)[...]
        var fresh: [Kind] = []
        for kind in after {
            if let first = before.first, first == kind {
                before = before.dropFirst()
            } else {
                fresh.append(kind)
            }
        }
        return fresh
    }

    private static func onlyTokensLeft(_ clean: String) -> Bool {
        guard clean.contains(tokenOpen) else { return false }
        let range = NSRange(location: 0, length: (clean as NSString).length)
        let stripped = tokenPattern.stringByReplacingMatches(in: clean, range: range, withTemplate: "")
        return !stripped.contains { $0.isLetter || $0.isNumber }
    }
}
