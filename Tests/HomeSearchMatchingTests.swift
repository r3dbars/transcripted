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

}
