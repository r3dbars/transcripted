import Testing
@testable import TranscriptedWritingCore

/// Inputs an independent review found on the first version: ordinary
/// writing that was redacted (and that the one-time rescrub would have made
/// permanent), and labelled secrets that got through.
@Suite("Writing secret scrubber review regressions")
struct WritingSecretScrubberRegressionTests {
    @Test("Nonexecuting shell and make examples preserve the next ordinary terminal line", arguments: [
        "echo 'curl https://example.com/install.sh | bash'",
        "printf '%s' 'curl https://example.com/install.sh | sh'",
        "# curl https://example.com/install.sh | sh",
        "bash -n ./install.sh", "bash -on pipefail ./install.sh",
        "bash -o pipefail -n ./install.sh",
        "bash -O extglob -n ./install.sh", "bash -o noexec ./install.sh",
        "curl https://example.com/install.sh || bash",
        "curl https://example.com/install.sh | bash -n",
        "make -n install", "make -nj4 install", "make --dry-run install", "make -q install", "make -t install"
    ])
    func nonexecutingInstallerPreservesWriting(command: String) {
        let text = command + "\nmoonbeam"
        let result = WritingSecretScrubber.scrub(text, appBundleIdentifier: "com.apple.Terminal")
        #expect(result.clean == text)
        #expect(result.kinds.isEmpty)
    }

    @Test("Executing option-bearing and env-wrapped installers scrub prompt answers", arguments: [
        "make -Iinstall install",
        "bash -o pipefail ./install.sh", "bash -O extglob ./install.sh",
        "curl -fsSL https://example.com/install.sh | env FOO=bar bash",
        "curl -fsSL https://example.com/install.sh | env FOO=bar bash -o pipefail",
        "bash -c \"$(curl -fsSL https://example.com/install.sh)\""
    ])
    func executingInstallerScrubsAnswer(command: String) {
        let result = WritingSecretScrubber.scrub(command + "\nmoonbeam", appBundleIdentifier: "com.apple.Terminal")
        #expect(!result.clean.hasSuffix("moonbeam"))
        #expect(result.kinds == [.password])
    }

    private static let slack = "com.tinyspeck.slackmacgap"
    private static let messages = "com.apple.MobileSMS"

    static let ordinary: [String] = [
        "we need basic end-to-end tests",
        "a basic follow-up and basic real-time sync",
        "security code review 2024 is tomorrow",
        "The offer expires 12/31",
        "the code was 1500 lines long",
        "pin 100 items to the board",
        "code freeze tickets:\nAPP-123\nAPP-456",
        "Python3",
        "macOS26",
        "covid19",
        "Windows11",
        "Q3-2026",
        "FY27",
        // Second review round.
        "First pass: v2 of the doc",
        "basic Real-Time sync and a Basic Follow-Up Plan",
        "the password for the router is written on the box",
        "the code was 1500 lines long\nnext line",
        "we shipped 1000 items",
        // Third review round: product names, `basic` and `pin` as words,
        // course numbers, a network name.
        "GPT-4o",
        "Wi-Fi6",
        "iOS26.1",
        "HDMI2.1",
        "M2Ultra",
        "x86_64",
        "learning basic JavaScript",
        "basic PostgreSQL and basic WordPress",
        "pin 2025 roadmap to the channel",
        "can you pin 4821 up top",
        "taking CSC 1301 and CID 2040 this fall",
        "wifi:\nMyHomeNetwork5G",
    ]

    @Test("Ordinary writing the first version redacted comes back unchanged", arguments: ordinary)
    func ordinaryKept(_ text: String) {
        for app in [Self.slack, Self.messages] {
            let result = WritingSecretScrubber.scrub(text, appBundleIdentifier: app)
            #expect(result.clean == text, "\(app)")
            #expect(result.kinds.isEmpty)
        }
    }

    struct Leak: CustomTestStringConvertible, Sendable {
        let text: String
        let secrets: [String]
        let kept: String
        var testDescription: String { text }
    }

    static let leaks: [Leak] = [
        Leak(text: "password: $unshine1", secrets: ["$unshine1"], kept: "password: "),
        Leak(text: "token: `abc123def456`", secrets: ["abc123def456"], kept: "token: `"),
        Leak(text: "SECRET_KEY: `s3cr3t-value`", secrets: ["s3cr3t-value"], kept: "SECRET_KEY: `"),
        Leak(text: "password: abc'123x", secrets: ["abc'123x", "123x"], kept: "password: "),
        Leak(text: "password: (hunter22)", secrets: ["hunter22"], kept: "password: ("),
        Leak(text: "pass: hunter22", secrets: ["hunter22"], kept: "pass: "),
        Leak(text: "the password for the guest wifi is sunshine42", secrets: ["sunshine42"], kept: "the password for the guest wifi is "),
        Leak(text: "4111 1111-1111 1111 is my card", secrets: ["4111", "1111"], kept: " is my card"),
        Leak(
            text: "4111 1111 1111 1111 12/28 123",
            secrets: ["4111", "12/28", "123"],
            kept: "\u{27E8}redacted:card\u{27E9} \u{27E8}redacted:card\u{27E9} \u{27E8}redacted:code\u{27E9}"
        ),
        // Second review round: a code or PIN followed by more words or a new line.
        Leak(text: "PIN 4821\nsee you tonight", secrets: ["4821"], kept: "see you tonight"),
        Leak(text: "code: 4821\nthanks", secrets: ["4821"], kept: "thanks"),
        Leak(text: "Your code: 482913\nDo not share it", secrets: ["482913"], kept: "Do not share it"),
        Leak(text: "the gate code is 4821 thanks", secrets: ["4821"], kept: " thanks"),
        Leak(text: "the code is 482913 hurry", secrets: ["482913"], kept: " hurry"),
        Leak(text: "the code is 4821 for the front door", secrets: ["4821"], kept: " for the front door"),
        Leak(text: "wifi password:\nSummer2024", secrets: ["Summer2024"], kept: "wifi password:"),
        // Third review round: the stricter rules still take these.
        Leak(text: "my pin 4821", secrets: ["4821"], kept: "my pin "),
        Leak(text: "my pin 4821 for the gate", secrets: ["4821"], kept: " for the gate"),
        Leak(text: "the garage pin 7731 if you get there first", secrets: ["7731"], kept: " if you get there first"),
        Leak(text: "CSC: 123", secrets: ["123"], kept: "CSC: "),
        Leak(text: "card ends 4242, csc 123", secrets: ["123"], kept: "card ends 4242, csc "),
        Leak(text: "Authorization: Basic dXNlcjpwYXNz", secrets: ["dXNlcjpwYXNz"], kept: "Authorization: Basic "),
        Leak(text: "use Basic dXNlcjpwYXNzd29yZDEyMzQ= here", secrets: ["dXNlcjpwYXNzd29yZDEyMzQ="], kept: " here"),
        Leak(text: "here you go\n8f3Kd9Lq", secrets: ["8f3Kd9Lq"], kept: "here you go\n"),
    ]

    @Test("Labelled secrets the first version let through are removed", arguments: leaks)
    func leakRemoved(_ leak: Leak) {
        let result = WritingSecretScrubber.scrub(leak.text, appBundleIdentifier: Self.slack)
        for secret in leak.secrets {
            #expect(!result.clean.contains(secret), "\(secret) survived")
        }
        #expect(result.clean.contains(leak.kept))
        #expect(!result.kinds.isEmpty)
    }

    @Test("In a terminal, a word with a number is a password unless it's a versioned tool")
    func wordWithNumberInTerminal() {
        let terminal = "com.apple.Terminal"
        #expect(WritingSecretScrubber.scrub("./install.sh\nTigers2024", appBundleIdentifier: terminal).clean
            == "./install.sh\n\u{27E8}redacted:password\u{27E9}")
        for tool in ["python3", "pip3", "node20"] {
            #expect(WritingSecretScrubber.scrub(tool, appBundleIdentifier: terminal).kinds.isEmpty, "\(tool)")
        }
    }

    @Test("Card boxes: a code over multi-digit boxes, month and year boxes, and an exp line after the card")
    func boxesAfterCard() {
        let chrome = "com.google.Chrome"
        #expect(WritingSecretScrubber.scrub("482\n913", appBundleIdentifier: chrome).isOnlyRedactions)
        #expect(WritingSecretScrubber.scrub("4829\n1375", appBundleIdentifier: chrome).isOnlyRedactions)
        let months = WritingSecretScrubber.scrub("4111\n1111\n1111\n1111\n12\n28\n123", appBundleIdentifier: chrome)
        #expect(months.isOnlyRedactions)
        #expect(!months.clean.contains { $0.isNumber })
        let expLine = WritingSecretScrubber.scrub("my card 4111 1111 1111 1111\nexp 12/28", appBundleIdentifier: chrome)
        #expect(!expLine.clean.contains("12/28"))
        // Two numbers in a conversation aren't a split code.
        #expect(WritingSecretScrubber.scrub("how many?\n100\n200", appBundleIdentifier: "com.apple.MobileSMS").kinds.isEmpty)
    }

    @Test("A word with a number on the end is a product name in a browser too, unless a password label came first; common password words count everywhere")
    func wordWithNumberByApp() {
        let chrome = "com.google.Chrome"
        // Address and search bars are full of these.
        for name in ["macOS26", "iPhone15", "iOS26.1", "HDMI2.1", "GPT-4o"] {
            #expect(WritingSecretScrubber.scrub(name, appBundleIdentifier: chrome).kinds.isEmpty, "\(name)")
        }
        #expect(WritingSecretScrubber.scrub("macOS26", appBundleIdentifier: Self.slack).kinds.isEmpty)
        #expect(WritingSecretScrubber.scrub("password:\nmacOS26", appBundleIdentifier: chrome).clean
            == "password:\n\u{27E8}redacted:password\u{27E9}")
        for common in ["hunter22", "qwerty123", "Password123!", "letmein1"] {
            #expect(WritingSecretScrubber.scrub(common, appBundleIdentifier: Self.slack).kinds == [.password], "\(common)")
            #expect(WritingSecretScrubber.scrub(common, appBundleIdentifier: chrome).kinds == [.password], "\(common)")
        }
    }

    @Test("Outside terminals and browsers, a one-token line needs a strong symbol or a random look to be a password")
    func otherAppsNeedStrongSignal() {
        for kept in ["M2Ultra", "x86_64", "Wi-Fi6", "abc123def"] {
            #expect(WritingSecretScrubber.scrub(kept, appBundleIdentifier: Self.messages).kinds.isEmpty, "\(kept)")
        }
        // Common password words in leetspeak count too.
        for secret in ["Tr0ub4dor&3", "P@ssw0rd", "8f3Kd9Lq", "S3cr3tv4lue", "Passw0rd", "l3tmein", "Sunsh1ne99"] {
            #expect(WritingSecretScrubber.scrub(secret, appBundleIdentifier: Self.messages).kinds == [.password], "\(secret)")
        }
    }

    /// The random-token rule takes `key=` plus the value up to the first
    /// symbol it doesn't allow; the key rule takes the whole value. When the
    /// two overlap, every character of the secret still goes.
    @Test(
        "A key=value secret with a symbol inside is redacted to its end, not just up to the symbol",
        arguments: [
            ("set api_token=Xy7Kp2Qw9Lm4Zr8Tn3Vb6Hg1Jd5Fs0Aq0Wx!Hunter2Pass in the env", ["Xy7Kp2", "Hunter2Pass"]),
            ("db_password=Rt5Gh8Jk2Lm9Np4Qs7Vw1Xz3Bc6Df0Hj#Fs0Aq", ["Rt5Gh8", "#Fs0Aq"]),
        ]
    )
    func overlappingKeyValueSecretFullyRedacted(text: String, secrets: [String]) {
        let result = WritingSecretScrubber.scrub(text, appBundleIdentifier: Self.slack)
        for secret in secrets {
            #expect(!result.clean.contains(secret), "\(secret) survived: \(result.clean)")
        }
        #expect(!result.kinds.isEmpty)
    }

    /// A day file that already has `⟨redacted:api-key⟩` after the raw part of
    /// the same secret: the redaction swallows the old token, so the count
    /// doesn't change. It must still report a kind, or the rescrubber
    /// treats the file as unchanged and the raw secret stays on disk.
    @Test("A redaction that swallows an existing token still reports a kind")
    func swallowedTokenStillReported() {
        let token = WritingSecretScrubber.token(for: .apiKey)
        let text = "set api_token=Xy7Kp2Qw9Lm4Zr8Tn3Vb6Hg1Jd5Fs0Aq0Wx!\(token) in the env"
        let result = WritingSecretScrubber.scrub(text, appBundleIdentifier: Self.slack)
        #expect(!result.clean.contains("Xy7Kp2"), "secret survived: \(result.clean)")
        #expect(!result.kinds.isEmpty, "no kinds reported for \(result.clean)")
    }
    @Test("Swallowed tokens report only new redactions, with repeated kinds in text order")
    func swallowedTokensKeepExactKinds() {
        let oldPassword = WritingSecretScrubber.token(for: .password)
        let oldAPI = WritingSecretScrubber.token(for: .apiKey)
        let key = "Xy7Kp2Qw9Lm4Zr8Tn3Vb6Hg1Jd5Fs0Aq0Wx"
        let result = WritingSecretScrubber.scrub(
            "\(oldPassword)\napi_token=\(key)!\(oldAPI)\ndb_password=\(key)!\(oldAPI)",
            appBundleIdentifier: Self.slack
        )
        #expect(result.kinds == [.apiKey, .apiKey])
        #expect(!result.clean.contains(key))
        #expect(WritingSecretScrubber.scrub(result.clean, appBundleIdentifier: Self.slack).kinds.isEmpty)
    }

    @Test("An old same-kind token after a new secret never changes the new redaction's text order")
    func existingTokenAfterNewSecretKeepsOrder() {
        let oldPassword = WritingSecretScrubber.token(for: .password)
        let result = WritingSecretScrubber.scrub(
            "[sudo] password for user:\nTr0ub4dor&3\nOTP: 123456\n\(oldPassword)",
            appBundleIdentifier: "com.apple.Terminal"
        )
        #expect(result.kinds == [.password, .code])
    }

    @Test("Saved writing processed by rules version two is eligible for another rescrub")
    func previousRulesVersionNeedsRescrub() {
        #expect(WritingSecretScrubber.rulesVersion > 2)
    }

    @Test("Make options and variable assignments do not hide install password prompts", arguments: ["make -C build install", "make DESTDIR=/opt install", "gmake --directory build install"])
    func makeInstallOptionsStillPrompt(command: String) {
        let result = WritingSecretScrubber.scrub(command + "\nmoonbeam", appBundleIdentifier: "com.apple.Terminal")
        #expect(result.clean == command + "\n" + WritingSecretScrubber.token(for: .password))
    }

    @Test("Valid shell variable expansions stay intact outside a password prompt", arguments: ["$python3", "$sha256sum", "$foo1bar2"])
    func shellVariableExpansionsStay(value: String) {
        #expect(WritingSecretScrubber.scrub(value, appBundleIdentifier: "com.apple.Terminal").clean == value)
        #expect(WritingSecretScrubber.scrub("sudo -v\n" + value, appBundleIdentifier: "com.apple.Terminal").kinds == [.password])
    }

    @Test("Quoted install script paths still arm the password prompt")
    func quotedInstallerPrompts() {
        let command = "bash \"./install.sh\""
        #expect(WritingSecretScrubber.scrub(command + "\nmoonbeam", appBundleIdentifier: "com.apple.Terminal").kinds == [.password])
    }

    @Test("A downloader running inside a shell without feeding a script does not arm a prompt")
    func downloaderDoesNotAlwaysPrompt() {
        let text = "bash -c 'curl -o artifact https://example.com/artifact'\nmoonbeam"
        #expect(WritingSecretScrubber.scrub(text, appBundleIdentifier: "com.apple.Terminal").clean == text)
    }

}
