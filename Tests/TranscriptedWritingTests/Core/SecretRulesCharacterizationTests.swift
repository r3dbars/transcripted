import Testing
@testable import TranscriptedWritingCore

// Split so the repo's secret scanner doesn't flag these test-only fakes.
private let fakeAWSKey = "AKIA" + "IOSFODNN7EXAMPLE"
private let fakeOpenAIKey = "sk-" + "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOP1234"
private let fakeGitHubToken = "ghp_" + "1234567890abcdefghijklmnopqrstuvwxyzAB"
private let fakePEMHeader = "-----BEGIN " + "PRIVATE KEY-----"

/// Pins `SecretRules.scrub` output byte for byte under all three configs.
/// The expected values were captured from the rules as they were before the
/// patterns became compiled-once statics, so any drift in matching (rule
/// order, pattern options, UTF-16 vs grapheme semantics) shows up here.
/// Synthetic strings and public example values only.
@Suite("Secret rules characterization")
struct SecretRulesCharacterizationTests {
    enum Config: Sendable {
        case prompt, persist, structured

        var scrub: SecretRules.ScrubConfig {
            switch self {
            case .prompt: return .forPromptContext
            case .persist: return .forPersistence
            case .structured:
                return .init(scrubEmails: false, scrubPhones: false, scrubGenericTokens: false, scrubCardNumbers: false)
            }
        }
    }

    typealias Row = (input: String, config: Config, clean: String, findings: [SecretRules.SecretType])

    static let table: [Row] = [
        ("Call me at 415-555-2671 or mail person@example.com today.", .prompt, "Call me at 415-555-2671 or mail person@example.com today.", []),
        ("Call me at 415-555-2671 or mail person@example.com today.", .persist, "Call me at \u{27e8}redacted:phone\u{27e9} or mail \u{27e8}redacted:email\u{27e9} today.", [.phone, .email]),
        ("Call me at 415-555-2671 or mail person@example.com today.", .structured, "Call me at 415-555-2671 or mail person@example.com today.", []),
        ("card 4111 1111 1111 1111 12/26 thanks", .prompt, "card \u{27e8}redacted:card\u{27e9} 12/26 thanks", [.creditCard]),
        ("card 4111 1111 1111 1111 12/26 thanks", .persist, "card \u{27e8}redacted:card\u{27e9} 12/26 thanks", [.creditCard]),
        ("card 4111 1111 1111 1111 12/26 thanks", .structured, "card 4111 1111 1111 1111 12/26 thanks", []),
        ("IBAN GB82 WEST 1234 5698 7654 32 for the invoice", .prompt, "IBAN \u{27e8}redacted:iban\u{27e9} for the invoice", [.iban]),
        ("IBAN GB82 WEST 1234 5698 7654 32 for the invoice", .persist, "IBAN \u{27e8}redacted:iban\u{27e9} for the invoice", [.iban]),
        ("IBAN GB82 WEST 1234 5698 7654 32 for the invoice", .structured, "IBAN \u{27e8}redacted:iban\u{27e9} for the invoice", [.iban]),
        ("ssn 212-34-5678 and 000-12-3456", .prompt, "ssn \u{27e8}redacted:ssn\u{27e9} and 000-12-3456", [.ssn]),
        ("ssn 212-34-5678 and 000-12-3456", .persist, "ssn \u{27e8}redacted:ssn\u{27e9} and 000-12-3456", [.ssn]),
        ("ssn 212-34-5678 and 000-12-3456", .structured, "ssn \u{27e8}redacted:ssn\u{27e9} and 000-12-3456", [.ssn]),
        ("keys \(fakeAWSKey) \(fakeOpenAIKey) \(fakeGitHubToken)", .prompt, "keys \u{27e8}redacted:api-key\u{27e9} \u{27e8}redacted:api-key\u{27e9} \u{27e8}redacted:api-key\u{27e9}", [.apiKey, .apiKey, .apiKey]),
        ("keys \(fakeAWSKey) \(fakeOpenAIKey) \(fakeGitHubToken)", .persist, "keys \u{27e8}redacted:api-key\u{27e9} \u{27e8}redacted:api-key\u{27e9} \u{27e8}redacted:api-key\u{27e9}", [.apiKey, .apiKey, .apiKey]),
        ("keys \(fakeAWSKey) \(fakeOpenAIKey) \(fakeGitHubToken)", .structured, "keys \u{27e8}redacted:api-key\u{27e9} \u{27e8}redacted:api-key\u{27e9} \u{27e8}redacted:api-key\u{27e9}", [.apiKey, .apiKey, .apiKey]),
        ("token aZ9kQ2mN7xL4vB8wT1yR6cJ3hD5sU0gP+f/=_zzz end", .prompt, "token \u{27e8}redacted:api-key\u{27e9} end", [.apiKey]),
        ("token aZ9kQ2mN7xL4vB8wT1yR6cJ3hD5sU0gP+f/=_zzz end", .persist, "token \u{27e8}redacted:api-key\u{27e9} end", [.apiKey]),
        ("token aZ9kQ2mN7xL4vB8wT1yR6cJ3hD5sU0gP+f/=_zzz end", .structured, "token aZ9kQ2mN7xL4vB8wT1yR6cJ3hD5sU0gP+f/=_zzz end", []),
        ("see xeyJhbGciOiJIUzI1NiJ9.eyJzdWIiOiIxIn0.c2lnbmF0dXJl and eyJhbGciOiJIUzI1NiJ9.eyJzdWIiOiIxIn0.c2lnbmF0dXJl", .prompt, "see xeyJhbGciOiJIUzI1NiJ9.eyJzdWIiOiIxIn0.c2lnbmF0dXJl and \u{27e8}redacted:jwt\u{27e9}", [.jwt]),
        ("see xeyJhbGciOiJIUzI1NiJ9.eyJzdWIiOiIxIn0.c2lnbmF0dXJl and eyJhbGciOiJIUzI1NiJ9.eyJzdWIiOiIxIn0.c2lnbmF0dXJl", .persist, "see xeyJhbGciOiJIUzI1NiJ9.eyJzdWIiOiIxIn0.c2lnbmF0dXJl and \u{27e8}redacted:jwt\u{27e9}", [.jwt]),
        ("see xeyJhbGciOiJIUzI1NiJ9.eyJzdWIiOiIxIn0.c2lnbmF0dXJl and eyJhbGciOiJIUzI1NiJ9.eyJzdWIiOiIxIn0.c2lnbmF0dXJl", .structured, "see xeyJhbGciOiJIUzI1NiJ9.eyJzdWIiOiIxIn0.c2lnbmF0dXJl and \u{27e8}redacted:jwt\u{27e9}", [.jwt]),
        ("\(fakePEMHeader)\nMIIBVQIBADANBgkqhkiG9w0BAQEFAASCAT8wggE7AgEA\n-----END PRIVATE KEY----- after", .prompt, "\u{27e8}redacted:pem\u{27e9} after", [.pem]),
        ("\(fakePEMHeader)\nMIIBVQIBADANBgkqhkiG9w0BAQEFAASCAT8wggE7AgEA\n-----END PRIVATE KEY----- after", .persist, "\u{27e8}redacted:pem\u{27e9} after", [.pem]),
        ("\(fakePEMHeader)\nMIIBVQIBADANBgkqhkiG9w0BAQEFAASCAT8wggE7AgEA\n-----END PRIVATE KEY----- after", .structured, "\u{27e8}redacted:pem\u{27e9} after", [.pem]),
        ("adjacent:person@example.com415-555-2671 x212-34-5678", .prompt, "adjacent:person@example.com415-555-2671 x\u{27e8}redacted:ssn\u{27e9}", [.ssn]),
        ("adjacent:person@example.com415-555-2671 x212-34-5678", .persist, "adjacent:person@example.com\u{27e8}redacted:phone\u{27e9} x\u{27e8}redacted:ssn\u{27e9}", [.phone, .ssn]),
        ("adjacent:person@example.com415-555-2671 x212-34-5678", .structured, "adjacent:person@example.com415-555-2671 x\u{27e8}redacted:ssn\u{27e9}", [.ssn]),
        ("emoji \u{1f44b}\u{1f3fd} cafe\u{301} 4111-1111-1111-1111 \u{2705} (415) 555-2671", .prompt, "emoji \u{1f44b}\u{1f3fd} cafe\u{301} \u{27e8}redacted:card\u{27e9} \u{2705} (415) 555-2671", [.creditCard]),
        ("emoji \u{1f44b}\u{1f3fd} cafe\u{301} 4111-1111-1111-1111 \u{2705} (415) 555-2671", .persist, "emoji \u{1f44b}\u{1f3fd} cafe\u{301} \u{27e8}redacted:card\u{27e9} \u{2705} \u{27e8}redacted:phone\u{27e9}", [.creditCard, .phone]),
        ("emoji \u{1f44b}\u{1f3fd} cafe\u{301} 4111-1111-1111-1111 \u{2705} (415) 555-2671", .structured, "emoji \u{1f44b}\u{1f3fd} cafe\u{301} 4111-1111-1111-1111 \u{2705} (415) 555-2671", []),
        ("line one\r\nline two \(fakeAWSKey)\r\n", .prompt, "line one\r\nline two \u{27e8}redacted:api-key\u{27e9}\r\n", [.apiKey]),
        ("line one\r\nline two \(fakeAWSKey)\r\n", .persist, "line one\r\nline two \u{27e8}redacted:api-key\u{27e9}\r\n", [.apiKey]),
        ("line one\r\nline two \(fakeAWSKey)\r\n", .structured, "line one\r\nline two \u{27e8}redacted:api-key\u{27e9}\r\n", [.apiKey]),
        ("Just ordinary prose with no secrets, version 1.2.3 and id 550e8400-e29b-41d4-a716-446655440000.", .prompt, "Just ordinary prose with no secrets, version 1.2.3 and id 550e8400-e29b-41d4-a716-446655440000.", []),
        ("Just ordinary prose with no secrets, version 1.2.3 and id 550e8400-e29b-41d4-a716-446655440000.", .persist, "Just ordinary prose with no secrets, version 1.2.3 and id 550e8400-e29b-41d4-a716-446655440000.", []),
        ("Just ordinary prose with no secrets, version 1.2.3 and id 550e8400-e29b-41d4-a716-446655440000.", .structured, "Just ordinary prose with no secrets, version 1.2.3 and id 550e8400-e29b-41d4-a716-446655440000.", []),
    ]

    @Test("Scrub output and findings match the captured table, byte for byte")
    func matchesCapturedTable() {
        for row in Self.table {
            let result = SecretRules.scrub(row.input, config: row.config.scrub)
            #expect(Array(result.clean.utf8) == Array(row.clean.utf8), "clean bytes drifted for \(row.config)")
            #expect(result.findings.map(\.type) == row.findings, "findings drifted for \(row.config)")
        }
    }

    @Test("Scrubbing A, then B, then A again gives A the same bytes both times")
    func repeatedScrubsShareNoState() {
        let a = Self.table[0]
        let b = Self.table[3]
        let first = SecretRules.scrub(a.input, config: a.config.scrub)
        _ = SecretRules.scrub(b.input, config: b.config.scrub)
        let again = SecretRules.scrub(a.input, config: a.config.scrub)
        #expect(Array(first.clean.utf8) == Array(again.clean.utf8))
        #expect(first.findings == again.findings)
    }

    @Test("Concurrent scrubs equal serial scrubs")
    func concurrentScrubsMatchSerial() async {
        let rows = Self.table
        let serial = rows.map { Array(SecretRules.scrub($0.input, config: $0.config.scrub).clean.utf8) }
        let rounds = 8
        let concurrent = await withTaskGroup(of: (Int, [UInt8]).self) { group in
            for round in 0..<rounds {
                for (index, row) in rows.enumerated() {
                    group.addTask {
                        (round * rows.count + index, Array(SecretRules.scrub(row.input, config: row.config.scrub).clean.utf8))
                    }
                }
            }
            var collected: [Int: [UInt8]] = [:]
            for await (key, bytes) in group { collected[key] = bytes }
            return collected
        }
        #expect(concurrent.count == rounds * rows.count)
        for (key, bytes) in concurrent {
            #expect(bytes == serial[key % rows.count])
        }
    }

    /// The fit loop re-scrubs each shortened line. Re-scrubbing a suffix is
    /// not idempotent: "xeyJ…" only becomes a JWT once the leading "x" is
    /// cut. Dropping that per-pass scrub would leak the token's tail.
    @Test("A JWT glued to a letter is fully redacted once the fit loop trims the line")
    func fitLoopRescrubsEachPass() {
        let recipe = RawContinuationPrompt(
            textBeforeCursor: "ok",
            register: .chat,
            scene: .init(
                mode: .replying,
                conversationTurns: [
                    .init(speaker: .other, text: "see xeyJhbGciOiJIUzI1NiJ9.eyJzdWIiOiIxIn0.c2lnbmF0dXJl"),
                ],
                referenceSnippets: []
            ),
            maxContextCharacters: 80
        )
        #expect(recipe.prompt.contains("{\"speaker\":\"them\",\"text\":\"\u{27E8}redacted:jwt\u{27E9}\"}\n"))
        #expect(!recipe.prompt.contains("c2lnbmF0dXJl"))
    }
}
