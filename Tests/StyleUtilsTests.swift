// StyleUtilsTests.swift
// Tests for StyleUtils — pure functions extracted from StyleEngine

func testStyleUtils() {
    // MARK: - extractRecentEditDistances

    runSuite("extractRecentEditDistances — parses EDIT_DISTANCE from examples") {
        let content = """
        # Writing Style Profile

        ## Style Summary
        Some summary

        ## Examples

        ### Example 1
        PLATFORM: slack
        EDIT_DISTANCE: 0.42
        AI_DRAFT:
        Hey Sarah!

        USER_SENT:
        hey! yeah

        ### Example 2
        PLATFORM: imessage
        EDIT_DISTANCE: 0.15
        AI_DRAFT:
        Sure thing!

        USER_SENT:
        sure thing!

        ### Example 3
        PLATFORM: email
        EDIT_DISTANCE: 0.78
        AI_DRAFT:
        Dear colleague

        USER_SENT:
        hey
        """
        let distances = StyleUtils.extractRecentEditDistances(last: 10, styleFileContents: content)
        assertEqual(distances.count, 3, "should find 3 distances")
        assertEqual(distances[0], 0.42, "first distance")
        assertEqual(distances[1], 0.15, "second distance")
        assertEqual(distances[2], 0.78, "third distance")
    }

    runSuite("extractRecentEditDistances — respects last N") {
        let content = """
        ## Examples

        ### Example 1
        EDIT_DISTANCE: 0.10

        ### Example 2
        EDIT_DISTANCE: 0.20

        ### Example 3
        EDIT_DISTANCE: 0.30

        ### Example 4
        EDIT_DISTANCE: 0.40
        """
        let last2 = StyleUtils.extractRecentEditDistances(last: 2, styleFileContents: content)
        assertEqual(last2.count, 2, "should get last 2")
        assertEqual(last2[0], 0.30, "third example")
        assertEqual(last2[1], 0.40, "fourth example")
    }

    runSuite("extractRecentEditDistances — empty content") {
        let distances = StyleUtils.extractRecentEditDistances(last: 10, styleFileContents: "")
        assertEqual(distances.count, 0, "no examples means no distances")
    }

    runSuite("extractRecentEditDistances — missing EDIT_DISTANCE tag") {
        let content = """
        ## Examples

        ### Example 1
        PLATFORM: slack
        AI_DRAFT: hello
        USER_SENT: hi
        """
        let distances = StyleUtils.extractRecentEditDistances(last: 10, styleFileContents: content)
        assertEqual(distances.count, 0, "no EDIT_DISTANCE tag means no distances")
    }

    // MARK: - averageRecentEditDistance

    runSuite("averageRecentEditDistance — computes average") {
        let content = """
        ## Examples

        ### Example 1
        EDIT_DISTANCE: 0.20

        ### Example 2
        EDIT_DISTANCE: 0.40

        ### Example 3
        EDIT_DISTANCE: 0.60
        """
        let avg = StyleUtils.averageRecentEditDistance(last: 10, styleFileContents: content)
        assertTrue(abs(avg - 0.40) < 0.001, "average should be 0.40, got \(avg)")
    }

    runSuite("averageRecentEditDistance — returns 1.0 for empty") {
        let avg = StyleUtils.averageRecentEditDistance(last: 10, styleFileContents: "")
        assertEqual(avg, 1.0, "empty content returns 1.0 (worst case)")
    }

    // MARK: - shouldRefineNow

    runSuite("shouldRefineNow — zero examples returns false") {
        assertFalse(StyleUtils.shouldRefineNow(exampleCount: 0, styleFileContents: ""))
    }

    runSuite("shouldRefineNow — early phase refines every 3") {
        // No edit distances in content (empty), so these just test the modulo logic
        assertFalse(StyleUtils.shouldRefineNow(exampleCount: 1, styleFileContents: ""))
        assertFalse(StyleUtils.shouldRefineNow(exampleCount: 2, styleFileContents: ""))
        assertTrue(StyleUtils.shouldRefineNow(exampleCount: 3, styleFileContents: ""))
        assertFalse(StyleUtils.shouldRefineNow(exampleCount: 4, styleFileContents: ""))
        assertFalse(StyleUtils.shouldRefineNow(exampleCount: 5, styleFileContents: ""))
        assertTrue(StyleUtils.shouldRefineNow(exampleCount: 6, styleFileContents: ""))
        assertTrue(StyleUtils.shouldRefineNow(exampleCount: 9, styleFileContents: ""))
        assertTrue(StyleUtils.shouldRefineNow(exampleCount: 12, styleFileContents: ""))
        assertTrue(StyleUtils.shouldRefineNow(exampleCount: 18, styleFileContents: ""))
        assertTrue(StyleUtils.shouldRefineNow(exampleCount: 15, styleFileContents: ""))
    }

    runSuite("shouldRefineNow — mature phase with low edit distance refines every 10") {
        // Build content with 25 examples all having low edit distances (< 0.25)
        var content = "## Examples\n"
        for i in 1...25 {
            content += "\n### Example \(i)\nEDIT_DISTANCE: 0.10\n"
        }
        assertTrue(StyleUtils.shouldRefineNow(exampleCount: 30, styleFileContents: content))
        assertFalse(StyleUtils.shouldRefineNow(exampleCount: 25, styleFileContents: content))
        assertFalse(StyleUtils.shouldRefineNow(exampleCount: 21, styleFileContents: content))
    }

    runSuite("shouldRefineNow — mature phase with high edit distance refines every 5") {
        // Build content with examples having high edit distances (>= 0.25)
        var content = "## Examples\n"
        for i in 1...25 {
            content += "\n### Example \(i)\nEDIT_DISTANCE: 0.50\n"
        }
        assertTrue(StyleUtils.shouldRefineNow(exampleCount: 25, styleFileContents: content))
        assertFalse(StyleUtils.shouldRefineNow(exampleCount: 21, styleFileContents: content))
        assertFalse(StyleUtils.shouldRefineNow(exampleCount: 22, styleFileContents: content))
    }

    // MARK: - wordEditDistance

    runSuite("wordEditDistance — identical strings") {
        let d = StyleUtils.wordEditDistance("hello world", "hello world")
        assertEqual(d, 0.0, "identical strings = 0 distance")
    }

    runSuite("wordEditDistance — completely different") {
        let d = StyleUtils.wordEditDistance("hello world", "foo bar")
        assertEqual(d, 1.0, "no overlap = 1.0 distance")
    }

    runSuite("wordEditDistance — partial overlap") {
        let d = StyleUtils.wordEditDistance("hello world foo", "hello world bar")
        // 2 common out of 3 total = 1 - 2/3 = 0.333...
        assertTrue(abs(d - (1.0 / 3.0)) < 0.001, "partial overlap, got \(d)")
    }

    runSuite("wordEditDistance — case insensitive") {
        let d = StyleUtils.wordEditDistance("Hello World", "hello world")
        assertEqual(d, 0.0, "case should not matter")
    }

    runSuite("wordEditDistance — both empty") {
        let d = StyleUtils.wordEditDistance("", "")
        assertEqual(d, 0.0, "both empty = 0 distance")
    }

    runSuite("wordEditDistance — one empty") {
        let d = StyleUtils.wordEditDistance("hello world", "")
        assertEqual(d, 1.0, "one empty = 1.0 distance")
    }

    // MARK: - extractRecentExamplesText

    runSuite("extractRecentExamplesText — extracts last N examples") {
        let content = """
        ## Style Summary
        some text

        ## Examples

        ### Example 1
        PLATFORM: slack
        USER_SENT:
        hey yeah that sounds good to me

        ### Example 2
        PLATFORM: email
        USER_SENT:
        let me check on that and get back to you tomorrow

        ### Example 3
        PLATFORM: imessage
        USER_SENT:
        sounds good see you there at seven
        """
        let last2 = StyleUtils.extractRecentExamplesText(last: 2, styleFileContents: content)
        assertFalse(last2.contains("hey yeah that sounds good"), "should not contain example 1")
        assertTrue(last2.contains("let me check on that"), "should contain example 2")
        assertTrue(last2.contains("sounds good see you"), "should contain example 3")
    }

    runSuite("extractRecentExamplesText — empty content") {
        let result = StyleUtils.extractRecentExamplesText(last: 5, styleFileContents: "")
        assertEqual(result, "", "empty content returns empty string")
    }

    runSuite("extractRecentExamplesText — preserves example headers") {
        let content = """
        ## Examples

        ### Example 1
        EDIT_DISTANCE: 0.50
        USER_SENT:
        this is a message that is long enough to pass the quality filter
        """
        let result = StyleUtils.extractRecentExamplesText(last: 5, styleFileContents: content)
        assertTrue(result.contains("### Example"), "should preserve ### Example header")
    }

    runSuite("extractRecentExamplesText — filters out short USER_SENT") {
        let content = """
        ## Examples

        ### Example 1
        PLATFORM: slack
        USER_SENT:
        hey yeah that sounds good to me lets do it

        ### Example 2
        PLATFORM: slack
        USER_SENT:
        ok

        ### Example 3
        PLATFORM: email
        USER_SENT:
        let me check on that and get back to you
        """
        let result = StyleUtils.extractRecentExamplesText(last: 5, styleFileContents: content)
        assertTrue(result.contains("hey yeah that sounds good"), "should include quality example 1")
        assertFalse(result.contains("\nok\n"), "should filter out short example 2")
        assertTrue(result.contains("let me check on that"), "should include quality example 3")
    }

    runSuite("extractRecentExamplesText — returns empty when all examples are low quality") {
        let content = """
        ## Examples

        ### Example 1
        PLATFORM: slack
        USER_SENT:
        ok

        ### Example 2
        PLATFORM: slack
        USER_SENT:
        hi there
        """
        let result = StyleUtils.extractRecentExamplesText(last: 5, styleFileContents: content)
        assertEqual(result, "", "all low-quality examples should result in empty string")
    }
}
