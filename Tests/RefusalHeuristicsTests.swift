// RefusalHeuristicsTests.swift
// Tests for RefusalHeuristics.looksLikeRefusal()

func testRefusalHeuristics() {
    runSuite("RefusalHeuristics.looksLikeRefusal — known refusal phrases") {
        assertTrue(RefusalHeuristics.looksLikeRefusal("I need the actual message to help you"), "need actual")
        assertTrue(RefusalHeuristics.looksLikeRefusal("I need more context to draft a reply"), "need context")
        assertTrue(RefusalHeuristics.looksLikeRefusal("Could you provide the conversation?"), "could you provide")
        assertTrue(RefusalHeuristics.looksLikeRefusal("I'd need to see the full thread"), "need to see")
        assertTrue(RefusalHeuristics.looksLikeRefusal("Please provide the message content"), "please provide")
        assertTrue(RefusalHeuristics.looksLikeRefusal("I can't write a reply without more info"), "can't write")
        assertTrue(RefusalHeuristics.looksLikeRefusal("I don't have enough information"), "don't have enough")
    }

    runSuite("RefusalHeuristics.looksLikeRefusal — case insensitivity") {
        assertTrue(RefusalHeuristics.looksLikeRefusal("I NEED THE ACTUAL message"), "uppercase")
        assertTrue(RefusalHeuristics.looksLikeRefusal("i need more context"), "lowercase")
        assertTrue(RefusalHeuristics.looksLikeRefusal("Could You Provide the details?"), "mixed case")
    }

    runSuite("RefusalHeuristics.looksLikeRefusal — new refusal phrases (contamination fix)") {
        assertTrue(RefusalHeuristics.looksLikeRefusal("I'm ready to help! Go ahead and share the message"), "ready to help")
        assertTrue(RefusalHeuristics.looksLikeRefusal("I don't see a conversation to respond to"), "no conversation")
        assertTrue(RefusalHeuristics.looksLikeRefusal("The screenshot shows terminal output"), "screenshot shows")
        assertTrue(RefusalHeuristics.looksLikeRefusal("Go ahead and share the message you need"), "go ahead share")
        assertTrue(RefusalHeuristics.looksLikeRefusal("What did the person say that you're responding to?"), "what did person say")
        assertTrue(RefusalHeuristics.looksLikeRefusal("Not a messaging conversation. Could you share the actual chat?"), "not messaging")
    }

    runSuite("RefusalHeuristics.looksLikeRefusal — normal messages") {
        assertFalse(RefusalHeuristics.looksLikeRefusal("Sure, I'll be there at 3pm"), "normal response")
        assertFalse(RefusalHeuristics.looksLikeRefusal("Hey thanks for letting me know!"), "casual message")
        assertFalse(RefusalHeuristics.looksLikeRefusal("Sounds good to me"), "short response")
        assertFalse(RefusalHeuristics.looksLikeRefusal(""), "empty string")
        assertFalse(RefusalHeuristics.looksLikeRefusal("Let me know what you need"), "contains 'need' but not a refusal phrase")
    }
}
