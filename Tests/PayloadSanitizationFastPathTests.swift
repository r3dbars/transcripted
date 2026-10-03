import Foundation

// Promise: the byte-level fast paths in PayloadSanitizationCore (category,
// shouldDrop) give exactly the answers the old regex / lowercased-substring
// checks gave, and cached build metadata never replaces an injected
// info dictionary.
func testPayloadSanitizationFastPath() {
    runSuite("PayloadSanitizationCore.category rejects secret-shaped and malformed values") {
        let rejected = [
            "sk-abc",
            "host.local",
            "ghp_" + String(repeating: "a", count: 20),
            "AKIA" + String(repeating: "B", count: 16),
            "abc\n",
            "abc\r\n",
            "abc\u{2028}",
            "-abc",
            "_abc",
            ".abc",
            "\u{E9}",
            "caf\u{E9}",
            "a b",
            "a/b",
            "",
            String(repeating: "a", count: 81),
        ]
        for value in rejected {
            assertNil(PayloadSanitizationCore.category(value), "category should reject \(value.debugDescription)")
        }
        assertNil(PayloadSanitizationCore.category(nil), "nil stays nil")
    }

    runSuite("PayloadSanitizationCore.category keeps categorical values") {
        let accepted = [
            "physical_key",
            "1.1.68",
            "no_audio",
            "a",
            "Z9-x.y_z",
            String(repeating: "a", count: 80),
        ]
        for value in accepted {
            assertEqual(PayloadSanitizationCore.category(value), value, "category should keep \(value.debugDescription)")
        }
    }

    runSuite("PayloadSanitizationCore.shouldDrop handles Unicode and plain keys") {
        let fragments = PayloadSanitizationCore.baseSensitiveKeyFragments
        // KELVIN SIGN lowercases to ASCII "k", so this key is "token".
        assertTrue(PayloadSanitizationCore.shouldDrop(key: "TO\u{212A}EN", sensitiveFragments: fragments), "Kelvin-sign TOKEN is still a token key")
        assertFalse(PayloadSanitizationCore.shouldDrop(key: "trigger", sensitiveFragments: fragments), "trigger is safe")
        assertTrue(PayloadSanitizationCore.shouldDrop(key: "Meeting_TITLE", sensitiveFragments: fragments), "mixed case still matches")
        assertTrue(PayloadSanitizationCore.shouldDrop(key: "start_profile", sensitiveFragments: fragments), "profile contains file")
        assertFalse(PayloadSanitizationCore.shouldDrop(key: "", sensitiveFragments: fragments), "empty key matches nothing")
    }

    runSuite("PayloadSanitizationCore.shouldDrop matches the lowercased-substring reference") {
        let fragmentLists: [[String]] = [
            PayloadSanitizationCore.baseSensitiveKeyFragments,
            ["Token", "x"],
            ["\u{E9}t\u{E9}"],
        ]
        let alphabet: [String] = [
            "a", "e", "f", "i", "l", "n", "m", "t", "o", "k", "x", "_", "-", ".", " ",
            "A", "E", "F", "I", "L", "N", "M", "T", "O", "K", "X",
            "\u{212A}", "\u{E9}", "e\u{301}", "\r\n", "\u{130}", "\u{DF}", "\u{1F3FB}",
        ]
        var generator = SeededGenerator(seed: 0x5EED_B19)
        for index in 0..<4_000 {
            let length = Int(generator.next() % 14)
            var key = ""
            for _ in 0..<length {
                key += alphabet[Int(generator.next() % UInt64(alphabet.count))]
            }
            if index % 5 == 0 {
                key += ["file", "name", "token", "url", "speaker"][Int(generator.next() % 5)]
            }
            for fragments in fragmentLists {
                let normalized = key.lowercased()
                let reference = fragments.contains(where: { normalized.contains($0) })
                assertEqual(
                    PayloadSanitizationCore.shouldDrop(key: key, sensitiveFragments: fragments),
                    reference,
                    "shouldDrop differs from reference for \(key.debugDescription)"
                )
            }
        }
    }

    runSuite("Capture plans keep each injected info dictionary's build identity") {
        func plan(channel: String, revision: String) -> ObservabilityEventCapturePlan {
            ObservabilityEventCapturePlan.make(
                level: .info,
                engine: "capture",
                event: "dictation_toggle_requested",
                message: "toggle",
                context: ["trigger": "physical_key"],
                engineState: nil,
                infoDictionary: [
                    "CFBundleVersion": "1",
                    AnalyticsRuntimeConfiguration.buildChannelInfoKey: channel,
                    AnalyticsRuntimeConfiguration.buildRevisionInfoKey: revision,
                ],
                timestamp: "2026-05-26T12:00:00.000Z",
                appVersion: "1.2.3",
                osVersion: "Version 26.0"
            )
        }
        let environment = ProcessInfo.processInfo.environment
        let first = plan(channel: "beta", revision: "abc1234")
        let second = plan(channel: "local", revision: "def5678")
        if environment[AnalyticsRuntimeConfiguration.buildChannelEnvironmentKey] == nil {
            assertEqual(first.mergedContext["build_channel"], "beta", "first plan keeps its channel")
            assertEqual(second.mergedContext["build_channel"], "local", "second plan keeps its channel")
        }
        if environment[AnalyticsRuntimeConfiguration.buildRevisionEnvironmentKey] == nil {
            assertEqual(first.mergedContext["build_revision"], "abc1234", "first plan keeps its revision")
            assertEqual(second.mergedContext["build_revision"], "def5678", "second plan keeps its revision")
        }
    }

    runSuite("TelemetryContext.enrich keeps a caller's build revision") {
        let enriched = TelemetryContext.enrich(
            event: "dictation_started",
            properties: ["build_revision": "caller-rev"],
            environment: [:]
        )
        assertEqual(enriched["build_revision"], "caller-rev", "an explicit revision is never replaced")
        let filled = TelemetryContext.enrich(event: "dictation_started", properties: [:], environment: [:])
        assertEqual(
            filled["build_revision"],
            AnalyticsRuntimeConfiguration.buildRevision(),
            "the cached process revision equals a fresh lookup"
        )
    }
}

private struct SeededGenerator {
    private var state: UInt64

    init(seed: UInt64) {
        state = seed
    }

    mutating func next() -> UInt64 {
        // SplitMix64: deterministic, so a failure reproduces exactly.
        state &+= 0x9E37_79B9_7F4A_7C15
        var value = state
        value = (value ^ (value >> 30)) &* 0xBF58_476D_1CE4_E5B9
        value = (value ^ (value >> 27)) &* 0x94D0_49BB_1331_11EB
        return value ^ (value >> 31)
    }
}
