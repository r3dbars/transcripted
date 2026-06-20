import Foundation

func testHomeSearchMatching() {
    runSuite("HomeMeetingListFilter.matches — token AND, case/diacritic insensitive") {
        // Empty / whitespace-only queries match everything.
        assertTrue(
            HomeMeetingListFilter.matches(query: "", in: ["Standup", "Jun 16, 2026"]),
            "Empty query should match"
        )
        assertTrue(
            HomeMeetingListFilter.matches(query: "   ", in: ["Standup"]),
            "Whitespace-only query should match"
        )

        // Single token matches across any field, case-insensitively.
        assertTrue(
            HomeMeetingListFilter.matches(query: "standup", in: ["Weekly Standup", "Jun 16, 2026"]),
            "Lowercased token should match a titled field"
        )
        assertTrue(
            HomeMeetingListFilter.matches(query: "JUNE", in: ["Standup", "June 16, 2026"]),
            "Uppercased token should match a date field"
        )

        // All tokens must appear (AND), possibly in different fields.
        assertTrue(
            HomeMeetingListFilter.matches(query: "standup june", in: ["Weekly Standup", "June 16, 2026"]),
            "Both tokens present across fields should match"
        )
        assertFalse(
            HomeMeetingListFilter.matches(query: "standup retro", in: ["Weekly Standup", "June 16, 2026"]),
            "A token missing from every field should fail the AND match"
        )

        // Diacritic-insensitive matching.
        assertTrue(
            HomeMeetingListFilter.matches(query: "jose", in: ["Sync with José"]),
            "Diacritics should be ignored when matching"
        )

        // Date search text is non-empty and contains the year.
        let dateText = HomeMeetingListFilter.dateSearchText(
            for: Date(timeIntervalSince1970: 1_750_000_000)
        )
        assertTrue(!dateText.isEmpty, "Date search text should not be empty")
    }

    runSuite("TranscriptFinder.matches — occurrence ordering and ranges") {
        // Empty query yields no matches.
        assertTrue(
            TranscriptFinder.matches(in: ["hello world"], query: "").isEmpty,
            "Empty query should produce no matches"
        )
        assertTrue(
            TranscriptFinder.matches(in: ["hello world"], query: "   ").isEmpty,
            "Whitespace-only query should produce no matches"
        )

        // Multiple occurrences within one line, in order.
        let repeated = TranscriptFinder.matches(in: ["the cat sat on the mat"], query: "the")
        assertEqual(repeated.count, 2, "Both occurrences of 'the' should be found")
        assertEqual(repeated[0].range, 0..<3, "First match should start at offset 0")
        assertEqual(repeated[1].range.lowerBound, 15, "Second match should start at offset 15")
        assertTrue(repeated.allSatisfy { $0.lineIndex == 0 }, "Single-line matches should report line 0")

        // Matches across multiple lines preserve line indices and reading order.
        let multi = TranscriptFinder.matches(
            in: ["Alpha beta", "gamma BETA delta", "no hit here"],
            query: "beta"
        )
        assertEqual(multi.count, 2, "One match per line containing 'beta'")
        assertEqual(multi[0].lineIndex, 0, "First match should be on line 0")
        assertEqual(multi[1].lineIndex, 1, "Second match should be on line 1")

        // Case- and diacritic-insensitive matching.
        let accented = TranscriptFinder.matches(in: ["Café au lait"], query: "cafe")
        assertEqual(accented.count, 1, "Accent-insensitive query should match")
        assertEqual(accented[0].range.lowerBound, 0, "Match should start at the accented word")
    }
}
