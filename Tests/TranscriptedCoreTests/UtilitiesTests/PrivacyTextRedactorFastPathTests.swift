import XCTest
@testable import TranscriptedCore

/// Promise: PrivacyTextRedactor's ASCII fast path and byte gates never change
/// output. `redact` must equal the plain regex chain for every input, under
/// both the app-observability and Core-log profiles.
final class PrivacyTextRedactorFastPathTests: XCTestCase {
    private struct Profile {
        let keys: Set<String>
        let embeddedPaths: Bool
    }

    private let profiles = [
        // App observability (ObservabilityTextRedactor).
        Profile(
            keys: [
                "attempt", "attempts", "code", "duration_ms", "error", "event", "failure_kind",
                "operation", "outcome", "reason", "stage", "status", "trigger", "wait_ms",
            ],
            embeddedPaths: true
        ),
        // Core logs (LogPrivacySanitizer).
        Profile(
            keys: ["attempt", "code", "duration", "error", "event", "operation", "reason", "stage", "status"],
            embeddedPaths: false
        ),
    ]

    private static let patternExamples: [String] = [
        "sk-x",
        "sk-abc",
        "host.local",
        "my-mac.local",
        "ghp_" + String(repeating: "a", count: 20),
        "github_pat_" + String(repeating: "b", count: 22),
        "phc_" + String(repeating: "C", count: 20),
        "AKIA" + String(repeating: "Q", count: 16),
        "ASIA" + String(repeating: "Z", count: 16),
        "AIza" + String(repeating: "x", count: 35),
        "xoxb-" + String(repeating: "1", count: 10),
        "xoxx-" + String(repeating: "2", count: 10),
        "eyJhbGciOiJIUzI1.eyJzdWIiOiIxMjM0.SflKxwRJSMeKKF2QT4",
        "-----BEGIN " + "RSA PRIVATE KEY-----\nabc\n-----END RSA PRIVATE KEY-----",
        "-----BEGIN " + "PRIVATE KEY-----",
        "Bearer x",
        "basic dXNlcjpwYXNz",
        "Authorization: Bearer abc",
        "/Users/a/b",
        "/Users/a/b.txt status=ok",
        "/private/tmp/x",
        "https://x",
        "http://example.com/a?b=c",
        "a@b.co",
        "(parakeet, Mic)",
        "(whisper, AirPods Pro)",
        "title=x",
        "token=x",
        "api_key: abc",
        "password=hunter2",
        "\"title\":\"Standup\"",
        "\"url\": \"https://x\"",
        "meeting_title=Weekly sync stage=done",
    ]

    private static let oddUnicode: [String] = [
        "host.local\u{1F3FB}",
        "host.local\u{E0020}",
        "TO\u{212A}EN",
        "a\u{2028}b",
        "a\u{00A0}b",
        "a\r\nb",
        "caf\u{E9}",
        "e\u{301}.local",
        "\u{FF0F}Users\u{FF0F}a",
        "\u{1F600}",
        "",
        " ",
        "\t\n",
        " padded ",
    ]

    private static let plainFragments: [String] = [
        "true", "false", "physical_key", "dictation_toggle_requested", "1.1.68", "no_audio",
        "0F8B9E1C-2D3A-4B5C-8D7E-6F5A4B3C2D1E", "[redacted-sensitive-value]", "abc", "x", "-", "_", ".",
        "s", "k", "loca", "local", "xo", "ey", "AK", "gh", "ph", "AI", "--", "----",
    ]

    private static let guardFragments: [String] = ["/", ":", "=", "@", "\"", "(", ")", " ", "\n", "\t", ",", ";"]

    func testRedactMatchesReferenceOnFixedExamples() {
        let inputs = Self.patternExamples + Self.oddUnicode + Self.plainFragments + Self.guardFragments
        for input in inputs {
            assertParity(input)
        }
    }

    func testRedactMatchesReferenceOnSeededCorpus() {
        let pieces = Self.patternExamples + Self.oddUnicode + Self.plainFragments + Self.guardFragments
            + ["sk-", ".local", "-----", "ghp_", "github_pat_", "phc_", "AKIA", "ASIA", "AIza", "xox", "eyJ"]
        var generator = SplitMix64(seed: 0xB19_F12)
        for _ in 0..<20_000 {
            let count = 1 + Int(generator.next() % 5)
            var input = ""
            for _ in 0..<count {
                input += pieces[Int(generator.next() % UInt64(pieces.count))]
            }
            assertParity(input)
        }
    }

    func testFixedOutputsStayTheSame() {
        let keys = profiles[0].keys
        XCTAssertEqual(
            PrivacyTextRedactor.redact("host.local\u{1F3FB}", pathDiagnosticMetadataKeys: keys, redactEmbeddedAbsolutePaths: true),
            "[redacted-host]\u{1F3FB}"
        )
        XCTAssertEqual(
            PrivacyTextRedactor.redact("dictation_toggle_requested", pathDiagnosticMetadataKeys: keys, redactEmbeddedAbsolutePaths: true),
            "dictation_toggle_requested"
        )
        XCTAssertEqual(
            PrivacyTextRedactor.redact("AKIA" + String(repeating: "Q", count: 16), pathDiagnosticMetadataKeys: keys, redactEmbeddedAbsolutePaths: true),
            "[redacted-secret]"
        )
        XCTAssertEqual(
            PrivacyTextRedactor.redact("sk-abc", pathDiagnosticMetadataKeys: keys, redactEmbeddedAbsolutePaths: true),
            "sk-****"
        )
        XCTAssertEqual(
            PrivacyTextRedactor.redact("my-mac.local", pathDiagnosticMetadataKeys: keys, redactEmbeddedAbsolutePaths: true),
            "[redacted-host]"
        )
        XCTAssertEqual(
            PrivacyTextRedactor.redact("a@b.co", pathDiagnosticMetadataKeys: keys, redactEmbeddedAbsolutePaths: true),
            "[redacted-email]"
        )
    }

    private func assertParity(_ input: String, file: StaticString = #filePath, line: UInt = #line) {
        for profile in profiles {
            let fast = PrivacyTextRedactor.redact(
                input,
                pathDiagnosticMetadataKeys: profile.keys,
                redactEmbeddedAbsolutePaths: profile.embeddedPaths
            )
            let reference = PrivacyTextRedactor.redactWithoutFastPaths(
                input,
                pathDiagnosticMetadataKeys: profile.keys,
                redactEmbeddedAbsolutePaths: profile.embeddedPaths
            )
            XCTAssertEqual(fast, reference, "fast path changed output for \(input.debugDescription)", file: file, line: line)
        }
    }
}

private struct SplitMix64 {
    private var state: UInt64

    init(seed: UInt64) {
        state = seed
    }

    mutating func next() -> UInt64 {
        state &+= 0x9E37_79B9_7F4A_7C15
        var value = state
        value = (value ^ (value >> 30)) &* 0xBF58_476D_1CE4_E5B9
        value = (value ^ (value >> 27)) &* 0x94D0_49BB_1331_11EB
        return value ^ (value >> 31)
    }
}
