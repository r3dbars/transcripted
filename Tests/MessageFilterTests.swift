// MessageFilterTests.swift
// Tests for MessageFilter.shouldSkip()

func testMessageFilter() {
    runSuite("MessageFilter.shouldSkip — single characters") {
        assertTrue(MessageFilter.shouldSkip("k"), "single char")
        assertTrue(MessageFilter.shouldSkip("y"), "single char")
        assertTrue(MessageFilter.shouldSkip(" k "), "single char with spaces")
    }

    runSuite("MessageFilter.shouldSkip — pure emoji") {
        assertTrue(MessageFilter.shouldSkip("😀"), "single emoji")
        assertTrue(MessageFilter.shouldSkip("😀😂"), "two emoji")
        assertTrue(MessageFilter.shouldSkip("👍🏻"), "emoji with skin tone")
    }

    runSuite("MessageFilter.shouldSkip — tapbacks") {
        assertTrue(MessageFilter.shouldSkip("Liked a message"), "liked a message")
        assertTrue(MessageFilter.shouldSkip("Loved an image"), "loved an image")
        assertTrue(MessageFilter.shouldSkip("Laughed at a message"), "laughed at")
        assertTrue(MessageFilter.shouldSkip("Emphasized a message"), "emphasized")
        assertTrue(MessageFilter.shouldSkip(#"Liked "morning! dogs are out""#), "liked quoted")
        assertTrue(MessageFilter.shouldSkip("Liked \u{201C}hello\u{201D}"), "liked smart quotes")
    }

    runSuite("MessageFilter.shouldSkip — URL-only") {
        assertTrue(MessageFilter.shouldSkip("https://example.com"), "plain URL")
        assertTrue(MessageFilter.shouldSkip("http://example.com check"), "URL with one word")
        assertFalse(MessageFilter.shouldSkip("Check out https://example.com it's great"), "URL in sentence")
    }

    runSuite("MessageFilter.shouldSkip — substantive messages") {
        assertFalse(MessageFilter.shouldSkip("Hey, are you coming to lunch today?"), "normal question")
        assertFalse(MessageFilter.shouldSkip("Sure, sounds good to me"), "short response")
        assertFalse(MessageFilter.shouldSkip("I'll be there in 10 minutes"), "normal message")
        assertFalse(MessageFilter.shouldSkip("Thanks for letting me know about the meeting"), "longer message")
    }

    runSuite("MessageFilter.shouldSkip — edge cases") {
        assertTrue(MessageFilter.shouldSkip(""), "empty string")
        assertTrue(MessageFilter.shouldSkip("  "), "whitespace only")
        assertTrue(MessageFilter.shouldSkip("\n"), "newline only")
    }
}
