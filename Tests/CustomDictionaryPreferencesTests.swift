import Foundation

func testCustomDictionaryPreferences() {
    runSuite("CustomDictionaryPreferences defaults to an empty dictionary") {
        let (defaults, suiteName) = makeCustomDictionaryDefaults()
        defer { defaults.removePersistentDomain(forName: suiteName) }

        assertEqual(CustomDictionaryPreferences.rawText(userDefaults: defaults), "", "raw text should default empty")
        assertEqual(CustomDictionaryPreferences.entries(userDefaults: defaults), [], "entries should default empty")
    }

    runSuite("CustomDictionaryPreferences parses terms and corrections") {
        let rawText = """

        PostHog
        r three d bars -> r3dbars
        - parakeet tdt v3 => Parakeet TDT V3
        * jay son = JSON
        PostHog

        """

        let entries = CustomDictionaryPreferences.entries(from: rawText)

        assertEqual(
            entries,
            [
                CustomDictionaryEntry(spoken: "PostHog", replacement: "PostHog"),
                CustomDictionaryEntry(spoken: "r three d bars", replacement: "r3dbars"),
                CustomDictionaryEntry(spoken: "parakeet tdt v3", replacement: "Parakeet TDT V3"),
                CustomDictionaryEntry(spoken: "jay son", replacement: "JSON"),
            ],
            "parser should trim blank lines, bullets, corrections, and duplicate sources"
        )
    }

    runSuite("CustomDictionaryPreferences persists raw text") {
        let (defaults, suiteName) = makeCustomDictionaryDefaults()
        defer { defaults.removePersistentDomain(forName: suiteName) }

        CustomDictionaryPreferences.setRawText("post hog -> PostHog", userDefaults: defaults)

        assertEqual(
            CustomDictionaryPreferences.rawText(userDefaults: defaults),
            "post hog -> PostHog",
            "raw dictionary text should persist"
        )
        assertEqual(
            CustomDictionaryPreferences.entries(userDefaults: defaults),
            [CustomDictionaryEntry(spoken: "post hog", replacement: "PostHog")],
            "persisted raw text should parse into entries"
        )
    }

    runSuite("CustomDictionaryTextProcessor applies preferred casing and spoken corrections") {
        let entries = CustomDictionaryPreferences.entries(from: """
        PostHog
        r three d bars -> r3dbars
        g rpc -> gRPC
        c plus plus -> C++
        """)

        let corrected = CustomDictionaryTextProcessor.apply(
            to: "we use posthog, r three d bars, g rpc, and c plus plus.",
            entries: entries
        )

        assertEqual(
            corrected,
            "we use PostHog, r3dbars, gRPC, and C++.",
            "processor should apply dictionary replacements case-insensitively"
        )
    }

    runSuite("CustomDictionaryTextProcessor respects word boundaries") {
        let entries = [CustomDictionaryEntry(spoken: "cat", replacement: "CAT")]

        let corrected = CustomDictionaryTextProcessor.apply(
            to: "the cat should not alter concatenate or bobcat",
            entries: entries
        )

        assertEqual(
            corrected,
            "the CAT should not alter concatenate or bobcat",
            "processor should not replace inside larger words"
        )
    }

    runSuite("CustomDictionaryTextProcessor prefers longer terms and flexible spacing") {
        let entries = CustomDictionaryPreferences.entries(from: """
        llama -> Llama
        llama stack -> Llama Stack
        """)

        let corrected = CustomDictionaryTextProcessor.apply(
            to: "llama   stack uses llama",
            entries: entries
        )

        assertEqual(
            corrected,
            "Llama Stack uses Llama",
            "processor should match longer phrases before shorter terms and tolerate extra spaces"
        )
    }

    runSuite("CustomDictionaryTextProcessor escapes replacement templates") {
        let entries = [
            CustomDictionaryEntry(spoken: "home bin", replacement: "$HOME\\bin")
        ]

        let corrected = CustomDictionaryTextProcessor.apply(
            to: "open home bin",
            entries: entries
        )

        assertEqual(
            corrected,
            "open $HOME\\bin",
            "processor should preserve dollar signs and backslashes in replacements"
        )
    }
}

private func makeCustomDictionaryDefaults() -> (UserDefaults, String) {
    let suiteName = "CustomDictionaryPreferencesTests-\(UUID().uuidString)"
    let defaults = UserDefaults(suiteName: suiteName)!
    defaults.removePersistentDomain(forName: suiteName)
    return (defaults, suiteName)
}
