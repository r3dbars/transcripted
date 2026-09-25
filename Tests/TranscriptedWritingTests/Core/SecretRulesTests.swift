import Testing
@testable import TranscriptedWritingCore

@Suite("Secret redaction rules")
struct SecretRulesTests {
    // MARK: - Table-driven, one vector per rule

    /// Structured secrets: shape- and checksum-validated. These are the
    /// rule-layer's blocking recall bar — every one of these must vanish.
    /// Values are all publicly-documented test/example values (Visa's test
    /// card number, the ISO IBAN example, AWS's own example access key,
    /// jwt.io's example token) or synthetic strings shaped like the real
    /// thing; none is a real secret.
    private static let structuredVectors: [(name: String, type: SecretRules.SecretType, value: String)] = [
        ("Luhn-valid credit card", .creditCard, "4111 1111 1111 1111"),
        ("IBAN", .iban, "GB82 WEST 1234 5698 7654 32"),
        ("SSN", .ssn, "212-34-5678"),
        ("AWS access key", .apiKey, "AKIAIOSFODNN7EXAMPLE"),
        ("OpenAI-shaped key", .apiKey, "sk-abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOP1234"),
        ("GitHub token", .apiKey, "ghp_1234567890abcdefghijklmnopqrstuvwxyzAB"),
        ("Generic high-entropy token", .apiKey, "aZ9kQ2mN7xL4vB8wT1yR6cJ3hD5sU0gP+f/=_zzz"),
        (
            "JWT",
            .jwt,
            "eyJhbGciOiJIUzI1NiIsInR5cCI6IkpXVCJ9."
                + "eyJzdWIiOiIxMjM0NTY3ODkwIiwibmFtZSI6IkpvaG4gRG9lIiwiaWF0IjoxNTE2MjM5MDIyfQ."
                + "SflKxwRJSMeKKF2QT4fwpMeJf36POk6yJV_adQssw5c"
        ),
        (
            "PEM block",
            .pem,
            """
            -----BEGIN PRIVATE KEY-----
            MIIBVQIBADANBgkqhkiG9w0BAQEFAASCAT8wggE7AgEA
            AkEA1RkLXzHhVv1vZ8yQeF3nP0dJhK6mLxT9wS2cRbNqUo
            -----END PRIVATE KEY-----
            """
        ),
    ]

    /// Configurable PII: scrubbed for persistence, kept for prompt context.
    private static let piiVectors: [(name: String, type: SecretRules.SecretType, value: String)] = [
        ("Email", .email, "person@example.com"),
        ("Phone", .phone, "415-555-2671"),
    ]

    @Test("Every structured rule fires on its own test vector", arguments: structuredVectors)
    func structuredRuleFires(_ vector: (name: String, type: SecretRules.SecretType, value: String)) {
        let text = "Screen text before. \(vector.value) Screen text after."
        let result = SecretRules.scrub(text, config: .forPersistence)
        #expect(!result.clean.contains(vector.value), "\(vector.name) survived scrubbing")
        #expect(
            result.clean.contains("\u{27E8}redacted:\(vector.type.rawValue)\u{27E9}"),
            "\(vector.name) did not produce the expected redaction token"
        )
        #expect(result.findings.contains(SecretRules.Finding(type: vector.type)), "\(vector.name) missing from findings")
    }

    @Test("Email and phone fire under both configs (recall), differ in whether they persist", arguments: piiVectors)
    func piiRuleFires(_ vector: (name: String, type: SecretRules.SecretType, value: String)) {
        let text = "Screen text before. \(vector.value) Screen text after."

        let persisted = SecretRules.scrub(text, config: .forPersistence)
        #expect(!persisted.clean.contains(vector.value), "\(vector.name) survived persistence scrubbing")
        #expect(persisted.findings.contains(SecretRules.Finding(type: vector.type)))

        let prompted = SecretRules.scrub(text, config: .forPromptContext)
        #expect(prompted.clean.contains(vector.value), "\(vector.name) was scrubbed from prompt context")
        #expect(prompted.findings.isEmpty)
    }

    // MARK: - Planted-secrets corpus: 100% rule-layer recall

    @Test("Planted-secrets corpus: every structured secret is redacted, none survive")
    func plantedSecretsCorpusStructuredRecall() {
        var document = "Notes from the screen, mixed with real content.\n"
        for vector in Self.structuredVectors {
            document += "\(vector.name): \(vector.value)\n"
        }

        let result = SecretRules.scrub(document, config: .forPersistence)

        var missed: [String] = []
        for vector in Self.structuredVectors where result.clean.contains(vector.value) {
            missed.append(vector.name)
        }
        #expect(missed.isEmpty, "Missed structured secrets (not 100% recall): \(missed)")

        let structuredFindingCount = result.findings.count
        #expect(
            structuredFindingCount == Self.structuredVectors.count,
            "Expected \(Self.structuredVectors.count) findings, got \(structuredFindingCount)"
        )

        let recall = missed.isEmpty ? 1.0 : 1.0 - (Double(missed.count) / Double(Self.structuredVectors.count))
        #expect(recall == 1.0)
    }

    @Test("Planted-secrets corpus: email and phone also fully redacted for persistence")
    func plantedSecretsCorpusPIIRecall() {
        var document = "Notes from the screen, mixed with real content.\n"
        for vector in Self.piiVectors {
            document += "\(vector.name): \(vector.value)\n"
        }

        let result = SecretRules.scrub(document, config: .forPersistence)

        for vector in Self.piiVectors {
            #expect(!result.clean.contains(vector.value), "\(vector.name) survived scrubbing")
        }
        #expect(result.findings.count == Self.piiVectors.count)
    }

    // MARK: - False-positive guard: realistic clean text never gets touched

    /// Ordinary screen text with no secrets in it, deliberately including
    /// shapes that resemble but are not secrets: a bare 10-digit number
    /// (no separators, so not a phone), a git commit hash (low-diversity
    /// hex, so not a high-entropy token), a UUID (same reason), a hyphenated
    /// invoice number, and code/version-number snippets.
    private static let cleanCorpus: [String] = [
        "Let's grab coffee at 3pm tomorrow if that still works for you.",
        "The quarterly report shows revenue up twelve percent year over year.",
        #"git commit -m "Fix flaky retry logic in the socket reconnect path""#,
        "Your order will arrive in 3 to 5 business days, tracking number 8834471205.",
        "commit 4b825dc642cb6eb9a060e54bf8d69288fbee4904 fixed the regression.",
        "Session id 550e8400-e29b-41d4-a716-446655440000 expired, please sign in again.",
        "Meeting notes: revenue projections, hiring plan, and the Q3 roadmap.",
        "func scrub(_ text: String) -> (clean: String, findings: [Finding]) { }",
        "The train departs platform 4 at 10:15 and arrives by noon.",
        "Invoice INV-2026-081534 is due at the end of the month.",
        "She said the hike was about six miles round trip with great views.",
        "Server responded with status 200 after roughly 42 milliseconds.",
        "Please review PR #338 before the release goes out tonight.",
        "The recipe calls for two cups of flour and a pinch of salt.",
        "Version 6.2.0 adds strict concurrency checking to the package manifest.",
    ]

    @Test("Clean text corpus is never touched under persistence config", arguments: cleanCorpus)
    func cleanCorpusUntouchedForPersistence(_ sentence: String) {
        let result = SecretRules.scrub(sentence, config: .forPersistence)
        #expect(result.clean == sentence, "false positive: \(sentence)")
        #expect(result.findings.isEmpty, "unexpected finding in: \(sentence)")
    }

    @Test("Clean text corpus is never touched under prompt-context config", arguments: cleanCorpus)
    func cleanCorpusUntouchedForPromptContext(_ sentence: String) {
        let result = SecretRules.scrub(sentence, config: .forPromptContext)
        #expect(result.clean == sentence, "false positive: \(sentence)")
        #expect(result.findings.isEmpty, "unexpected finding in: \(sentence)")
    }

    // MARK: - Behavioral details

    @Test("Replacement tokens read exactly as ⟨redacted:type⟩")
    func replacementTokenFormat() {
        let result = SecretRules.scrub("Card 4111 1111 1111 1111 please.", config: .forPersistence)
        #expect(result.clean == "Card \u{27E8}redacted:card\u{27E9} please.")
    }

    @Test("Multiple distinct secrets in one string are each redacted without overlap corruption")
    func multipleSecretsInOneString() {
        let text = "Card 4111 1111 1111 1111 and SSN 212-34-5678 were both on screen."
        let result = SecretRules.scrub(text, config: .forPersistence)
        #expect(result.clean == "Card \u{27E8}redacted:card\u{27E9} and SSN \u{27E8}redacted:ssn\u{27E9} were both on screen.")
        #expect(result.findings.map(\.type) == [.creditCard, .ssn])
    }

    @Test("Empty text is a no-op")
    func emptyTextNoOp() {
        let result = SecretRules.scrub("", config: .forPersistence)
        #expect(result.clean.isEmpty)
        #expect(result.findings.isEmpty)
    }

    @Test("Invalid Luhn digit sequences are left alone")
    func invalidLuhnLeftAlone() {
        let text = "Reference number 4111 1111 1111 1112 is not a real card."
        let result = SecretRules.scrub(text, config: .forPersistence)
        #expect(result.clean == text)
        #expect(result.findings.isEmpty)
    }

    @Test("Invalid SSN shapes (666 area, all-zero group) are left alone")
    func invalidSSNShapeLeftAlone() {
        let text = "Not real SSNs: 666-12-3456 and 212-00-5678."
        let result = SecretRules.scrub(text, config: .forPersistence)
        #expect(result.clean == text)
        #expect(result.findings.isEmpty)
    }

    // MARK: - Regression: adjacent-digit / boundary false negatives

    @Test("Card number followed by an adjacent expiry date is still fully redacted")
    func cardNumberAdjacentToExpiryIsRedacted() {
        let text = "Card 4111 1111 1111 1111 12/26 on file."
        let result = SecretRules.scrub(text, config: .forPersistence)
        #expect(!result.clean.contains("4111 1111 1111 1111"), "card number survived alongside adjacent expiry digits")
        #expect(result.clean.contains("\u{27E8}redacted:card\u{27E9}"))
        #expect(result.clean.contains("12/26"), "expiry date should be left alone, only the card redacted")
    }

    @Test("Full-length IBAN prefix does not truncate at a shorter coincidentally-valid checksum")
    func ibanFullLengthNotTruncated() {
        let text = "Wire to FI2112345600000785 please."
        let result = SecretRules.scrub(text, config: .forPersistence)
        #expect(!result.clean.contains("5600000785"), "trailing IBAN account digits survived scrubbing")
        #expect(result.clean.contains("\u{27E8}redacted:iban\u{27E9}"))
        #expect(!result.clean.contains("785"), "IBAN should be redacted to its full 18-character mandated length")
    }

    @Test("Temporary AWS ASIA access keys are redacted like AKIA keys")
    func awsTemporaryAccessKeyRedacted() {
        let text = "Session key ASIAIOSFODNN7EXAMPLE was on screen."
        let result = SecretRules.scrub(text, config: .forPersistence)
        #expect(!result.clean.contains("ASIAIOSFODNN7EXAMPLE"))
        #expect(result.findings.contains(SecretRules.Finding(type: .apiKey)))
    }

    @Test("Phone number with parens and no trailing space is redacted")
    func phoneWithParensNoSpaceIsRedacted() {
        let text = "Call (415)555-2671 tomorrow."
        let result = SecretRules.scrub(text, config: .forPersistence)
        #expect(!result.clean.contains("(415)555-2671"))
        #expect(result.findings.contains(SecretRules.Finding(type: .phone)))
    }

    @Test("High-entropy token with a leading base64 symbol is fully redacted")
    func highEntropyTokenWithLeadingSymbolRedacted() {
        let text = "Token +aZ9kQ2mN7xL4vB8wT1yR6cJ3hD5sU0gP+f/=zzzz was on screen."
        let result = SecretRules.scrub(text, config: .forPersistence)
        #expect(!result.clean.contains("aZ9kQ2mN7xL4vB8wT1yR6cJ3hD5sU0gP"), "token survived, missing its leading symbol")
        #expect(result.findings.contains(SecretRules.Finding(type: .apiKey)))
    }
}
