import Testing
@testable import TranscriptedWritingCore

/// Promises for `WritingSecretScrubber`, written from the spec, not the code.
/// Every secret here is a publicly documented test value (Visa/Mastercard test
/// cards, AWS's example key, jwt.io's example token) or an obviously synthetic
/// string. Token-shaped strings are glued together with `+` so repository
/// secret scanners don't flag this file.
@Suite("Writing secret scrubber")
struct WritingSecretScrubberTests {
    typealias Kind = WritingSecretScrubber.Kind

    static let slack = "com.tinyspeck.slackmacgap"
    static let mail = "com.apple.mail"
    static let terminal = "com.apple.Terminal"

    // MARK: - 7. Tokens and the result

    @Test("A redaction token is ⟨redacted:<kind>⟩ with the kind's raw value", arguments: Kind.allCases)
    func tokenShape(_ kind: Kind) {
        #expect(WritingSecretScrubber.token(for: kind) == "\u{27E8}redacted:\(kind.rawValue)\u{27E9}")
    }

    @Test("Kind raw values are the spelled-out names, with api-key hyphenated")
    func kindRawValues() {
        #expect(Kind.password.rawValue == "password")
        #expect(Kind.code.rawValue == "code")
        #expect(Kind.card.rawValue == "card")
        #expect(Kind.secret.rawValue == "secret")
        #expect(Kind.apiKey.rawValue == "api-key")
        #expect(Kind.jwt.rawValue == "jwt")
        #expect(Kind.pem.rawValue == "pem")
        #expect(Kind.iban.rawValue == "iban")
        #expect(Kind.ssn.rawValue == "ssn")
    }

    @Test("Empty text comes back empty, with no kinds and not only-redactions")
    func emptyText() {
        let result = WritingSecretScrubber.scrub("", appBundleIdentifier: Self.slack)
        #expect(result.clean == "")
        #expect(result.kinds.isEmpty)
        #expect(result.isOnlyRedactions == false)
    }

    @Test("Kinds list one kind per redaction, in text order")
    func kindsInTextOrder() {
        let result = scrub("password: sunshine\n482913\n4111 1111 1111 1111")
        #expect(result.clean == "password: \(tok(.password))\n\(tok(.code))\n\(tok(.card))")
        #expect(result.kinds == [.password, .code, .card])
    }

    @Test("Only-redactions is true when nothing but tokens, whitespace and punctuation is left")
    func onlyRedactionsTrue() {
        let single = scrub("Tr0ub4dor&3")
        #expect(single.clean == tok(.password))
        #expect(single.isOnlyRedactions)

        let trailingNewline = scrub("482913\n")
        #expect(trailingNewline.clean == tok(.code) + "\n")
        #expect(trailingNewline.isOnlyRedactions)

        let punctuated = scrub("(4111 1111 1111 1111)")
        #expect(!punctuated.clean.contains("4111"))
        #expect(punctuated.isOnlyRedactions)

        let fromContext = scrub("sunshine", app: Self.terminal, preceding: ["sudo apt update"])
        #expect(fromContext.clean == tok(.password))
        #expect(fromContext.isOnlyRedactions)
    }

    @Test("Only-redactions is false when any real word or number remains")
    func onlyRedactionsFalse() {
        #expect(scrub("password: sunshine").isOnlyRedactions == false)
        #expect(scrub("Tr0ub4dor&3\nok").isOnlyRedactions == false)
        #expect(scrub("482913\n2026").isOnlyRedactions == false)
        #expect(scrub("sounds good").isOnlyRedactions == false)
        #expect(scrub("sudo -v\nsunshine", app: Self.terminal).isOnlyRedactions == false)
    }

    @Test("Scrubbing a clean result again changes nothing", arguments: idempotenceInputs)
    func idempotent(_ input: Input) {
        let once = WritingSecretScrubber.scrub(
            input.text, appBundleIdentifier: input.app, precedingLines: input.preceding
        )
        let twice = WritingSecretScrubber.scrub(
            once.clean, appBundleIdentifier: input.app, precedingLines: input.preceding
        )
        #expect(twice.clean == once.clean)
        #expect(twice.isOnlyRedactions == once.isOnlyRedactions)
    }

    // MARK: - 1. Structured secrets (every app)

    static let structuredVectors: [Vector] = [
        Vector("Luhn-valid Visa test card", "4111 1111 1111 1111", .card),
        Vector("Luhn-valid Mastercard test card", "5555555555554444", .card),
        Vector("IBAN", "GB82 WEST 1234 5698 7654 32", .iban),
        Vector("SSN", "212-34-5678", .ssn),
        Vector("AWS example access key", "AKIA" + "IOSFODNN7EXAMPLE", .apiKey),
        Vector("OpenAI-shaped key", "sk-" + "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOP1234", .apiKey),
        Vector("GitHub classic token", "ghp_" + "1234567890abcdefghijklmnopqrstuvwxyzAB", .apiKey),
        Vector("Generic high-entropy token", "aZ9kQ2mN7xL4vB8wT1yR6cJ3hD5sU0gP" + "+f/=_zzz", .apiKey),
        Vector(
            "jwt.io example JWT",
            "eyJhbGciOiJIUzI1NiIsInR5cCI6IkpXVCJ9."
                + "eyJzdWIiOiIxMjM0NTY3ODkwIiwibmFtZSI6IkpvaG4gRG9lIiwiaWF0IjoxNTE2MjM5MDIyfQ."
                + "SflKxwRJSMeKKF2QT4fwpMeJf36POk6yJV_adQssw5c",
            .jwt
        ),
        Vector("Slack bot token", "xox" + "b-" + "123456789012-1234567890123-" + synthetic(24), .apiKey),
        Vector("Slack user token", "xox" + "p-" + "123456789012-1234567890123-" + synthetic(24), .apiKey),
        Vector("Stripe live secret key", "sk_" + "live_" + synthetic(24), .apiKey),
        Vector("Stripe live restricted key", "rk_" + "live_" + synthetic(24), .apiKey),
        Vector("Google API key (39 chars)", "AI" + "za" + "Sy" + "0123456789abcdefghijklmnopqrstuvw", .apiKey),
        Vector("GitHub fine-grained token", "github_" + "pat_" + "11" + synthetic(20) + "_" + synthetic(59), .apiKey),
        Vector("GitLab token", "gl" + "pat-" + synthetic(20), .apiKey),
        Vector("npm token", "np" + "m_" + synthetic(36), .apiKey),
        Vector("Hugging Face token", "h" + "f_" + synthetic(34), .apiKey),
        Vector("SendGrid key", "S" + "G." + synthetic(22) + "." + synthetic(43), .apiKey),
        Vector("Telegram bot token", "123456789" + ":" + "AA" + synthetic(33), .apiKey),
    ]

    @Test(
        "A structured secret is replaced by its token and the words around it are kept",
        arguments: structuredVectors, [slack, mail, terminal]
    )
    func structuredSecret(_ vector: Vector, app: String) {
        let text = "Screen text before. \(vector.value) Screen text after."
        let result = scrub(text, app: app)
        #expect(!result.clean.contains(vector.value), "\(vector.name) survived")
        #expect(result.clean == "Screen text before. \(tok(vector.kind)) Screen text after.")
        #expect(result.kinds == [vector.kind])
    }

    @Test("A PEM block is replaced by the pem token and the text around it is kept")
    func pemBlock() {
        let body = "MIIBVQIBADANBgkqhkiG9w0BAQEFAASCAT8wggE7AgEA"
        let pem = "-----BEGIN " + "PRIVATE KEY-----\n" + body
            + "\nAkEA1RkLXzHhVv1vZ8yQeF3nP0dJhK6mLxT9wS2cRbNqUo\n-----END " + "PRIVATE KEY-----"
        let result = scrub("Here is the key\n\(pem)\nDon't share it")
        #expect(!result.clean.contains(body))
        #expect(!result.clean.contains("BEGIN"))
        #expect(result.clean.contains(tok(.pem)))
        #expect(result.clean.hasPrefix("Here is the key\n"))
        #expect(result.clean.hasSuffix("\nDon't share it"))
        #expect(result.kinds == [.pem])
    }

    @Test("Emails and phone numbers are the user's own writing and are kept", arguments: [slack, mail, terminal])
    func emailAndPhoneKept(app: String) {
        let text = "Email me at person@example.com or call 415-555-2671 after lunch."
        let result = scrub(text, app: app)
        #expect(result.clean == text)
        #expect(result.kinds.isEmpty)
    }

    // MARK: - 2. Terminal password prompts (terminal-like apps only)

    static let terminalLikeApps = [
        "com.apple.Terminal",
        "com.apple.terminal",
        "COM.APPLE.TERMINAL",
        "com.googlecode.iterm2",
        "com.mitchellh.ghostty",
        "net.kovidgoyal.kitty",
        "com.github.wez.wezterm",
        "com.microsoft.VSCode",
        "dev.zed.Zed",
        "com.jetbrains.intellij",
        "com.jetbrains.pycharm",
        "COM.JETBRAINS.WebStorm",
    ]

    static let notTerminalApps = [
        "com.tinyspeck.slackmacgap",
        "com.apple.mail",
        "com.apple.Safari",
        "com.apple.TextEdit",
        "com.apple.Notes",
        // Exact match, not a prefix, outside JetBrains.
        "com.apple.TerminalHelper",
        "com.googlecode.iterm2.extra",
    ]

    @Test("Terminals and editors with a built-in terminal are terminal-like", arguments: terminalLikeApps)
    func terminalLike(_ bundleIdentifier: String) {
        #expect(WritingSecretScrubber.isTerminalLike(bundleIdentifier))
    }

    @Test("Chat, mail, browsers and editors without a terminal are not terminal-like", arguments: notTerminalApps)
    func notTerminalLike(_ bundleIdentifier: String) {
        #expect(!WritingSecretScrubber.isTerminalLike(bundleIdentifier))
    }

    static let promptCommands = [
        "sudo apt update",
        "sudo -v",
        "su",
        "su - deploy",
        "doas pkg_add vim",
        "ssh deploy@example.com",
        "scp notes.txt deploy@example.com:/tmp",
        "sftp deploy@example.com",
        "mosh deploy@example.com",
        "passwd",
        "login",
        "mysql -u root -p",
        "mariadb -u root -p",
        "psql -h db.internal -U app",
        "docker login",
        "npm login",
        "vault login",
        "op signin",
        "kinit someone@EXAMPLE.COM",
        "ssh-add ~/.ssh/id_ed25519",
        "ssh-keygen -t ed25519",
        "gpg --decrypt notes.gpg",
        "openssl rsa -in server.key -out plain.key",
        "security unlock-keychain",
        "read -s answer",
        "read -rs answer",
        "read -sp \"Enter: \" answer",
        "git push https://example.com/team/app.git main",
        "git pull https://example.com/team/app.git",
        "git clone https://example.com/team/app.git",
        "git fetch https://example.com/team/app.git",
        "htpasswd -c .htpasswd admin",
        "keytool -list -keystore app.jks",
        "fdesetup enable",
        "ansible-playbook site.yml --ask-become-pass",
        "ansible all -m ping --ask-pass",
        "time ssh deploy@example.com",
        "env TERM=xterm ssh deploy@example.com",
        "sudo su -",
    ]

    @Test(
        "In a terminal, the one-word line after a password prompt is redacted and the command is kept",
        arguments: promptCommands
    )
    func terminalPromptAnswer(_ command: String) {
        // Letters only, so the standalone password rule (3) can't be what catches it.
        let result = scrub(command + "\nsunshine", app: Self.terminal)
        #expect(result.clean == command + "\n" + tok(.password))
        #expect(result.kinds == [.password])
    }

    @Test(
        "The prompting command can come from the previous entry, which never shows up in the result",
        arguments: promptCommands
    )
    func terminalPromptFromPrecedingLines(_ command: String) {
        let result = scrub("sunshine", app: Self.terminal, preceding: ["cd ~/code", command])
        #expect(result.clean == tok(.password))
        #expect(result.kinds == [.password])
        #expect(result.isOnlyRedactions)
    }

    @Test("Preceding lines are context only and never appear in the clean text")
    func precedingLinesNeverWritten() {
        let result = scrub("sunshine\nls -la", app: Self.terminal, preceding: ["cd ~/code", "sudo apt update"])
        #expect(result.clean == tok(.password) + "\nls -la")
        #expect(!result.clean.contains("sudo"))
        #expect(!result.clean.contains("cd ~/code"))

        let unrelated = scrub("hello there", app: Self.terminal, preceding: ["sudo apt update"])
        #expect(unrelated.clean == "hello there")
    }

    @Test("The prompting command can be an earlier line in the same entry")
    func terminalPromptEarlierInEntry() {
        let result = scrub("cd project\nsudo make install\nsunshine\nmake test", app: Self.terminal)
        #expect(result.clean == "cd project\nsudo make install\n\(tok(.password))\nmake test")
        #expect(result.kinds == [.password])
    }

    static let passphraseCommands = [
        "ssh-keygen -t ed25519",
        "ssh-add ~/.ssh/id_ed25519",
        "gpg --symmetric notes.txt",
        "openssl genrsa -aes256 -out server.key 2048",
        "read -s phrase",
    ]

    @Test("After a passphrase command, the next line is redacted even with spaces", arguments: passphraseCommands)
    func passphraseWithSpaces(_ command: String) {
        let result = scrub(command + "\ncorrect horse battery staple", app: Self.terminal)
        #expect(result.clean == command + "\n" + tok(.password))
        #expect(result.kinds == [.password])
    }

    @Test("After a plain password prompt, a line with spaces is kept")
    func passwordPromptLineWithSpacesKept() {
        let text = "sudo apt update\nthe build is done"
        #expect(scrub(text, app: Self.terminal).clean == text)
    }

    @Test("y, n, yes, no and q after a prompt are answers, not passwords", arguments: ["y", "n", "yes", "no", "q"])
    func shortAnswersKept(_ answer: String) {
        let text = "sudo apt upgrade\n" + answer
        let result = scrub(text, app: Self.terminal)
        #expect(result.clean == text)
        #expect(result.kinds.isEmpty)
    }

    @Test("A retry after a wrong sudo password is redacted when it looks like a password")
    func retryRedacted() {
        let result = scrub("sudo apt update\nsunshine\nhunter22", app: Self.terminal)
        #expect(result.clean == "sudo apt update\n\(tok(.password))\n\(tok(.password))")
        #expect(result.kinds == [.password, .password])
    }

    @Test("After sudo's one answer, a line that doesn't look like a password is the next command")
    func sudoTakesOneLooseAnswer() {
        // With cached credentials sudo doesn't ask, so `pytest` and `ruff`
        // (or an alias) are commands. Only the first line can't be told apart.
        let tools = scrub("sudo -v\nhunter2\npytest\nruff\nmytool", app: Self.terminal)
        #expect(tools.clean == "sudo -v\n\(tok(.password))\npytest\nruff\nmytool")
        #expect(tools.kinds == [.password])

        let lettersOnly = scrub("sudo apt update\nsunshine\nmoonbeam", app: Self.terminal)
        #expect(lettersOnly.clean == "sudo apt update\n\(tok(.password))\nmoonbeam")
    }

    @Test("ssh, scp and sftp take at most one answer", arguments: ["ssh deploy@example.com", "scp a.txt host:/tmp", "sftp host"])
    func sshTakesOneAnswer(_ command: String) {
        let result = scrub(command + "\nsunshine\nmytool", app: Self.terminal)
        #expect(result.clean == command + "\n\(tok(.password))\nmytool")
        #expect(result.kinds == [.password])
    }

    static let gitWithoutHTTPS = [
        "git push", "git pull", "git fetch origin", "git push -u origin main", "git push origin main",
        "git clone git@github.com:team/app.git", "git pull --rebase",
    ]

    @Test("git push, pull, fetch and clone don't prompt without an https URL on the line", arguments: gitWithoutHTTPS)
    func gitWithoutHTTPSDoesNotPrompt(_ command: String) {
        for next in ["gpull", "mytool", "sunshine"] {
            let text = command + "\n" + next
            #expect(scrub(text, app: Self.terminal).clean == text, "\(next)")
            #expect(scrub(next, app: Self.terminal, preceding: [command]).clean == next, "\(next) as the next entry")
        }
    }

    @Test("Login commands take a username and a password, and no third line")
    func loginTakesTwoAnswers() {
        let docker = scrub("docker login ghcr.io\njbetker\nsunshine\nmytool", app: Self.terminal)
        #expect(docker.clean == "docker login ghcr.io\n\(tok(.password))\n\(tok(.password))\nmytool")
        let git = scrub("jbetker\nsunshine\nmytool", app: Self.terminal, preceding: ["git clone https://example.com/team/app.git"])
        #expect(git.clean == "\(tok(.password))\n\(tok(.password))\nmytool")
    }

    @Test("A passphrase typed again to confirm it is redacted too, spaces and all")
    func passphraseConfirmationRedacted() {
        let result = scrub(
            "ssh-keygen -t ed25519\ncorrect horse battery staple\ncorrect horse battery staple\nls",
            app: Self.terminal
        )
        #expect(result.clean == "ssh-keygen -t ed25519\n\(tok(.password))\n\(tok(.password))\nls")
        #expect(result.kinds == [.password, .password])
    }

    @Test("A password token an earlier pass left counts as the prompt's answer")
    func redactedAnswerUsesUpPrompt() {
        let password = tok(.password)
        // sudo's answer is spent, so the next command is a command.
        #expect(scrub("mytool", app: Self.terminal, preceding: ["sudo -v", password]).clean == "mytool")
        // passwd has a third answer left after two.
        #expect(scrub("moonbeam", app: Self.terminal, preceding: ["passwd", password, password]).clean == password)
        #expect(scrub("moonbeam", app: Self.terminal, preceding: ["passwd", password, password, password]).clean == "moonbeam")
    }

    @Test("passwd's old, new and confirm lines are all redacted, and a fourth line is kept")
    func upToThreeAnswers() {
        let three = scrub("passwd\nsunshine\nmoonbeam\nmoonbeam", app: Self.terminal)
        #expect(three.clean == "passwd\n\(tok(.password))\n\(tok(.password))\n\(tok(.password))")
        #expect(three.kinds == [.password, .password, .password])

        let four = scrub("passwd\nsunshine\nmoonbeam\nmoonbeam\nstarlight", app: Self.terminal)
        #expect(four.clean == "passwd\n\(tok(.password))\n\(tok(.password))\n\(tok(.password))\nstarlight")
    }

    static let commandLikeLines = ["ls", "cd", "clear", "exit", "git", "pwd", "./deploy.sh", "/usr/bin/true", "~/bin", "git status"]

    @Test("Answer lines stop at the first line that looks like a command", arguments: commandLikeLines)
    func answersStopAtCommand(_ commandLine: String) {
        let text = "sudo -v\nsunshine\n\(commandLine)\nmoonbeam"
        let result = scrub(text, app: Self.terminal)
        #expect(result.clean == "sudo -v\n\(tok(.password))\n\(commandLine)\nmoonbeam")
        #expect(result.kinds == [.password])
    }

    @Test("A command typed right after sudo (no prompt shown) is kept", arguments: commandLikeLines)
    func commandRightAfterPromptKept(_ commandLine: String) {
        // Conservative reading: the "looks like a command" stop applies to the first answer line too.
        let text = "sudo -v\n\(commandLine)"
        #expect(scrub(text, app: Self.terminal).clean == text)
    }

    @Test("A password typed one character per line after a prompt is one redaction")
    func singleCharacterRunAfterPrompt() {
        let joined = scrub("sudo -v\nh\nu\nn\nt\ne\nr\n2", app: Self.terminal)
        #expect(joined.clean == "sudo -v\n" + tok(.password))
        #expect(joined.kinds == [.password])

        let lettersOnly = scrub("s\nu\nn\ns\nh\ni\nn\ne", app: Self.terminal, preceding: ["sudo -v"])
        #expect(lettersOnly.clean == tok(.password))
        #expect(lettersOnly.kinds == [.password])
    }

    @Test("In a terminal-prompt context, digits are a password")
    func digitsAfterPromptArePassword() {
        let pin = scrub("sudo -v\n1234", app: Self.terminal)
        #expect(pin.clean == "sudo -v\n" + tok(.password))
        #expect(pin.kinds == [.password])

        let sixDigits = scrub("482913", app: Self.terminal, preceding: ["ssh deploy@example.com"])
        #expect(sixDigits.clean == tok(.password))
        #expect(sixDigits.kinds == [.password])
    }

    @Test("Outside a terminal, a line after sudo is not treated as a password", arguments: [slack, mail])
    func promptRuleIsTerminalOnly(app: String) {
        let text = "sudo apt update\nsunshine"
        #expect(scrub(text, app: app).clean == text)
        #expect(scrub(text, app: app).kinds.isEmpty)

        let fromContext = scrub("sunshine", app: app, preceding: ["sudo apt update"])
        #expect(fromContext.clean == "sunshine")

        let passphrase = "ssh-keygen -t ed25519\ncorrect horse battery staple"
        #expect(scrub(passphrase, app: app).clean == passphrase)
    }

    @Test("Outside a terminal, other rules still apply after a sudo line")
    func otherRulesStillApplyOutsideTerminal() {
        let result = scrub("sudo apt update\nTr0ub4dor&3")
        #expect(result.clean == "sudo apt update\n" + tok(.password))
        #expect(result.kinds == [.password])
    }

    // MARK: - 3. Standalone password-shaped lines (every app)

    static let passwordShapedLines = ["Tr0ub4dor&3", "Password123!", "hunter22", "qwerty123", "P@ssw0rd"]

    @Test(
        "A one-token line that looks like a password is redacted in any app",
        arguments: passwordShapedLines, [slack, mail, terminal]
    )
    func standalonePassword(_ line: String, app: String) {
        let alone = scrub(line, app: app)
        #expect(alone.clean == tok(.password))
        #expect(alone.kinds == [.password])

        let between = scrub("here you go\n\(line)\nthanks", app: app)
        #expect(between.clean == "here you go\n\(tok(.password))\nthanks")
        #expect(between.kinds == [.password])
    }

    @Test("A password typed one character per line is judged as one line")
    func singleCharacterRunStandalone() {
        let result = scrub("h\nu\nn\nt\ne\nr\n2")
        #expect(result.clean == tok(.password))
        #expect(result.kinds == [.password])

        for kept in ["o\nk", "t\nh\na\nn\nk\ns"] {
            #expect(scrub(kept).clean == kept)
        }
    }

    @Test("A mixed letters-and-digits token under 6 characters is kept")
    func tooShortToBePassword() {
        #expect(scrub("a1b2c").clean == "a1b2c")
    }

    // MARK: - 4. One-time codes and PINs (every app)

    static let codeLines = ["482913", "1234567", "12345678", "482 913", "4829-1375", "4829 1375", "482-913"]

    @Test("A line of 6 to 8 digits is a one-time code", arguments: codeLines, [slack, mail, terminal])
    func sixToEightDigitCode(_ line: String, app: String) {
        let result = scrub(line, app: app)
        #expect(result.clean == tok(.code))
        #expect(result.kinds == [.code])
    }

    @Test("A code typed into split boxes, one digit per line, is one code")
    func splitOTPBoxes() {
        let six = scrub("4\n8\n2\n9\n1\n3")
        #expect(six.clean == tok(.code))
        #expect(six.kinds == [.code])

        let four = scrub("your code:\n4\n8\n2\n9")
        #expect(four.clean == "your code:\n" + tok(.code))

        #expect(scrub("1\n2\n3").clean == "1\n2\n3")
    }

    static let codeWords = ["code", "PIN", "OTP", "passcode", "verification", "2FA", "CVV", "CVC"]

    @Test("A 4 or 5 digit line is a code when the line before mentions a code word", arguments: codeWords)
    func shortCodeAfterCodeWord(_ word: String) {
        let four = scrub("here's the \(word)\n4821")
        #expect(four.clean == "here's the \(word)\n" + tok(.code))
        #expect(four.kinds == [.code])

        let five = scrub("here's the \(word)\n48213")
        #expect(five.clean == "here's the \(word)\n" + tok(.code))
    }

    @Test("A 4 or 5 digit line without a code word before it is kept", arguments: ["2026", "1000", "94110", "12345"])
    func shortNumbersKept(_ number: String) {
        #expect(scrub(number).clean == number)
        let afterProse = "the total came to\n\(number)"
        #expect(scrub(afterProse).clean == afterProse)
    }

    // MARK: - 5. Payment cards split across lines (every app)

    @Test("A card number split across lines is one card redaction")
    func splitCard() {
        let visa = scrub("4111\n1111\n1111\n1111")
        #expect(visa.clean == tok(.card))
        #expect(visa.kinds == [.card])

        let mastercard = scrub("5555\n5555\n5555\n4444", app: Self.mail)
        #expect(mastercard.clean == tok(.card))
        #expect(mastercard.kinds == [.card])
    }

    @Test("The CVV and expiry right after a card are redacted")
    func cvvAndExpiryAfterCard() {
        let inline = scrub("4111 1111 1111 1111\n123\n12/28")
        #expect(inline.clean == "\(tok(.card))\n\(tok(.code))\n\(tok(.card))")
        #expect(inline.kinds == [.card, .code, .card])

        let split = scrub("4111\n1111\n1111\n1111\n12/2028\n1234")
        #expect(split.clean == "\(tok(.card))\n\(tok(.card))\n\(tok(.code))")
        #expect(split.kinds == [.card, .card, .code])

        let spacedExpiry = scrub("5555 5555 5555 4444\n12 / 28")
        #expect(spacedExpiry.clean == "\(tok(.card))\n\(tok(.card))")
        #expect(spacedExpiry.kinds == [.card, .card])
    }

    @Test("Luhn-invalid digit groups, and a CVV or date with no card before it, are kept")
    func luhnInvalidKept() {
        let invalid = "4111\n1111\n1111\n1112"
        #expect(scrub(invalid).clean == invalid)
        #expect(scrub(invalid).kinds.isEmpty)

        let noCard = "room\n123\n12/28"
        #expect(scrub(noCard).clean == noCard)
    }

    // MARK: - 6. Labelled secrets inline (every app)

    static let labelledCases: [Labelled] = [
        // password-ish labels with : or =
        Labelled("password: sunshine", "password: ", "", .password),
        Labelled("password=sunshine", "password=", "", .password),
        Labelled("passwd: sunshine", "passwd: ", "", .password),
        Labelled("pwd: sunshine", "pwd: ", "", .password),
        Labelled("pw: sunshine", "pw: ", "", .password),
        Labelled("passcode: sunshine", "passcode: ", "", .password),
        Labelled("passphrase: sunshine", "passphrase: ", "", .password),
        Labelled("Password: sunshine", "Password: ", "", .password),
        Labelled("pin: 4821", "pin: ", "", .code),
        // "is" / "was"
        Labelled("the wifi password is sunshine", "the wifi password is ", "", .password),
        Labelled("my password was Hunter2", "my password was ", "", .password),
        Labelled("pw is abc123", "pw is ", "", .password),
        Labelled("the passcode is 9921", "the passcode is ", "", .password),
        Labelled("the pin is 4821", "the pin is ", "", .code),
        // code labels
        Labelled("verification code: 482913", "verification code: ", "", .code),
        Labelled("security code is 1234", "security code is ", "", .code),
        Labelled("one-time code = 5521", "one-time code = ", "", .code),
        Labelled("login code: 7788", "login code: ", "", .code),
        Labelled("2fa code: 123456", "2fa code: ", "", .code),
        Labelled("otp: 998877", "otp: ", "", .code),
        Labelled("OTP is 1234", "OTP is ", "", .code),
        // env-style
        Labelled("export OPENAI_API_KEY=abc123", "export OPENAI_API_KEY=", "", .secret),
        Labelled("github_token: abc", "github_token: ", "", .secret),
        Labelled("set SECRET=shh before running", "set SECRET=", " before running", .secret),
        Labelled("aws_access_key: foo", "aws_access_key: ", "", .secret),
        Labelled("export PRIVATE_KEY=bar", "export PRIVATE_KEY=", "", .secret),
        Labelled("client_credential: baz", "client_credential: ", "", .secret),
        Labelled("export APIKEY=qux", "export APIKEY=", "", .secret),
        Labelled("export AUTH_HEADER=xyz", "export AUTH_HEADER=", "", .secret),
        // CLI flags
        Labelled("mytool --password sunshine", "mytool --password ", "", .secret),
        Labelled("mytool --password=sunshine", "mytool --password=", "", .secret),
        Labelled("mytool --pass sunshine", "mytool --pass ", "", .secret),
        Labelled("mytool --passwd sunshine", "mytool --passwd ", "", .secret),
        Labelled("deploy --token abc123 --env prod", "deploy --token ", " --env prod", .secret),
        Labelled("deploy --secret abc123", "deploy --secret ", "", .secret),
        Labelled("deploy --api-key abc123", "deploy --api-key ", "", .secret),
        Labelled("deploy --apikey abc123", "deploy --apikey ", "", .secret),
        Labelled("deploy --auth-token abc123", "deploy --auth-token ", "", .secret),
        Labelled("deploy --client-secret abc123", "deploy --client-secret ", "", .secret),
        Labelled("mysql -u root -psunshine", "mysql -u root -p", "", .password),
        Labelled("sshpass -p sunshine ssh deploy@example.com", "sshpass -p ", " ssh deploy@example.com", .password),
        Labelled("redis-cli -h cache -a sunshine", "redis-cli -h cache -a ", "", .password),
        Labelled("curl -u admin:sunshine https://example.com/api", "curl -u admin:", " https://example.com/api", .password),
        Labelled("curl --user admin:sunshine https://example.com/api", "curl --user admin:", " https://example.com/api", .password),
        // Authorization headers
        Labelled("Authorization: Bearer abc123def", "Authorization: Bearer ", "", .secret),
        Labelled("Authorization: Basic YWxhZGRpbjpvcGVuc2VzYW1l", "Authorization: Basic ", "", .secret),
        Labelled("use Bearer abc123def for now", "use Bearer ", " for now", .secret),
        // URL credentials
        Labelled("https://admin:sunshine@example.com/path", "https://admin:", "@example.com/path", .password),
        Labelled("postgres://app:s3cret@db.internal:5432/app", "postgres://app:", "@db.internal:5432/app", .password),
    ]

    @Test(
        "A labelled secret loses its value and keeps its label",
        arguments: labelledCases, [slack, terminal]
    )
    func labelledSecret(_ labelled: Labelled, app: String) {
        let result = scrub(labelled.input, app: app)
        #expect(result.clean == labelled.prefix + tok(labelled.kind) + labelled.suffix)
        #expect(result.kinds == [labelled.kind])
    }

    @Test("A quoted env-style value is redacted and its key is kept")
    func quotedEnvValue() {
        // Spec example DB_PASSWORD="hunter2" is env-style (.secret). Whether the quotes
        // survive isn't pinned, and a bare one-token line would collide with rule 3,
        // so this checks the value is gone and the key kept.
        let result = scrub("export DB_PASSWORD=\"hunter2\"")
        #expect(!result.clean.contains("hunter2"))
        #expect(result.clean.hasPrefix("export DB_PASSWORD="))
        #expect(result.clean.contains(tok(.secret)))
        #expect(result.kinds == [.secret])
    }

    static let passwordIsCommonWord = [
        "my password is wrong",
        "my password is expiring",
        "the password is correct",
        "my password is incorrect",
        "my password is too short",
        "the password is not working",
        "the password is the same",
        "my password is still broken",
        "your password was reset",
        "the pin is required",
        "my password is expired",
        "the passcode is different",
        "my password is weak",
        "the password was changed",
        "the pw is saved",
        "my password is invalid",
        "that password is quickly guessed",
    ]

    @Test("\"password is <common word>\" is kept byte for byte", arguments: passwordIsCommonWord)
    func passwordIsCommonWordKept(_ text: String) {
        let result = scrub(text)
        #expect(result.clean == text)
        #expect(result.kinds.isEmpty)
    }

    // MARK: - Must stay byte-identical

    static let keptLines = [
        // Spec's "NOT redacted" list for rule 3.
        "ok", "thanks!", "Sounds good", "2026-09-28", "10:30", "v1.2.3", "1.1.65", "JIRA-1234",
        "COVID-19", "https://example.com/abc123", "github.com", "person@example.com", "@justin",
        "#launch2026", "./build.sh", "~/Downloads", "--force", "4th", "1080p", "$120", "50%",
        "iPhone", "camelCaseName", "snake_case", "well-known", "don't", ":thumbsup:",
    ]

    @Test("Everyday one-token lines are kept byte for byte", arguments: keptLines, [slack, mail, terminal])
    func keptLine(_ line: String, app: String) {
        let result = scrub(line, app: app)
        #expect(result.clean == line)
        #expect(result.kinds.isEmpty)
    }

    static let keptDocuments: [Input] = [
        Input(
            "Prose",
            "The password reset flow is confusing, so we should rewrite it next sprint.\n"
                + "Our PIN pad vendor shipped v2.4 yesterday and the token budget is 4096 per request.\n"
                + "My password is expiring tomorrow, so I'll reset it after the 10:30 standup.",
            app: "com.apple.TextEdit"
        ),
        Input(
            "Chat replies",
            "sounds good\nok\nlol\non my way\nthanks!\n👍\nsee you at 7:30\ncan you send the Q3 deck?\n"
                + "I'll be 10 min late\nI paid $120 for 2 tickets\nroom 204",
            app: slack
        ),
        Input(
            "Email",
            "Hi Sam,\n\nThanks for the notes from Tuesday. I moved the review to 10:30 on 2026-09-30 "
                + "and booked room 4B.\nCall me at 415-555-2671 or write to person@example.com.\n\nBest,\nJustin",
            app: mail
        ),
        Input(
            "Shopping list",
            "Shopping list\n2 apples\n12 eggs\noat milk",
            app: "com.apple.Notes"
        ),
        Input(
            "Swift snippet",
            #"""
            func greet(_ name: String) -> String {
                let message = "Hello, \(name)!"
                return message
            }
            """#,
            app: "com.apple.dt.Xcode"
        ),
        Input(
            "Terminal session: git and ls",
            "cd ~/code/transcripted\nls\ngit status\ngit log --oneline -5\npwd\nls -la ~/Downloads\nclear",
            app: terminal
        ),
        Input(
            "Terminal session: builds",
            "brew install ffmpeg\nbrew upgrade\nnpm install\nnpm run build\nswift build\n"
                + "swift test --filter WritingDayFile\nmake\nexit",
            app: terminal
        ),
        Input(
            "Terminal session: git push then a command",
            "git add -A\ngit commit -m \"Fix the title\"\ngit push origin main\ngit status",
            app: terminal
        ),
        Input(
            "Terminal session: sudo then an answer that's a command",
            "sudo apt update\nls -la",
            app: terminal
        ),
    ]

    @Test("Realistic writing with no secrets is kept byte for byte", arguments: keptDocuments)
    func keptDocument(_ input: Input) {
        let result = WritingSecretScrubber.scrub(
            input.text, appBundleIdentifier: input.app, precedingLines: input.preceding
        )
        #expect(result.clean == input.text)
        #expect(result.kinds.isEmpty)
        #expect(result.isOnlyRedactions == false)
    }

    static var idempotenceInputs: [Input] {
        var inputs = keptDocuments
        inputs += structuredVectors.map { Input($0.name, "before \($0.value) after", app: slack) }
        inputs += labelledCases.map { Input($0.input, $0.input, app: slack) }
        inputs += passwordShapedLines.map { Input($0, "here you go\n\($0)\nthanks", app: slack) }
        inputs += [
            Input("terminal prompt", "sudo apt update\nsunshine\nmoonbeam\nls", app: terminal),
            Input("terminal context", "sunshine", app: terminal, preceding: ["sudo apt update"]),
            Input("single chars after sudo", "sudo -v\nh\nu\nn\nt\ne\nr\n2", app: terminal),
            Input("passphrase", "ssh-keygen -t ed25519\ncorrect horse battery staple", app: terminal),
            Input("split OTP", "4\n8\n2\n9\n1\n3", app: slack),
            Input("card with CVV and expiry", "4111\n1111\n1111\n1111\n123\n12/28", app: slack),
            Input("short code after code word", "what's the PIN?\n4821", app: slack),
            Input("already a token", tok(.password), app: slack),
        ]
        return inputs
    }

    // MARK: - Helpers

    func scrub(_ text: String, app: String = Self.slack, preceding: [String] = []) -> WritingSecretScrubber.Result {
        WritingSecretScrubber.scrub(text, appBundleIdentifier: app, precedingLines: preceding)
    }

    func tok(_ kind: Kind) -> String { Self.tok(kind) }

    /// Spelled out here rather than calling `token(for:)`, so a wrong token shape fails.
    static func tok(_ kind: Kind) -> String { "\u{27E8}redacted:\(kind.rawValue)\u{27E9}" }

    /// Deterministic mixed-case alphanumerics, obviously not a real credential.
    static func synthetic(_ count: Int) -> String {
        let alphabet = Array("q7Wm3Zp9Kx2Rv8Ln4Bt6Hy5Jc1Fd0Gs")
        return String((0..<count).map { alphabet[$0 % alphabet.count] })
    }

    struct Vector: Sendable, CustomTestStringConvertible {
        let name: String
        let value: String
        let kind: Kind
        init(_ name: String, _ value: String, _ kind: Kind) {
            self.name = name
            self.value = value
            self.kind = kind
        }
        var testDescription: String { name }
    }

    struct Labelled: Sendable, CustomTestStringConvertible {
        let input: String
        let prefix: String
        let suffix: String
        let kind: Kind
        init(_ input: String, _ prefix: String, _ suffix: String, _ kind: Kind) {
            self.input = input
            self.prefix = prefix
            self.suffix = suffix
            self.kind = kind
        }
        var testDescription: String { input }
    }

    struct Input: Sendable, CustomTestStringConvertible {
        let name: String
        let text: String
        let app: String
        let preceding: [String]
        init(_ name: String, _ text: String, app: String, preceding: [String] = []) {
            self.name = name
            self.text = text
            self.app = app
            self.preceding = preceding
        }
        var testDescription: String { name }
    }
}
