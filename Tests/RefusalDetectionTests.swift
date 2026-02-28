// RefusalDetectionTests.swift
// Tests for DraftUtils.looksLikeRefusal()

func testRefusalDetection() {
    runSuite("DraftUtils.looksLikeRefusal — known refusal phrases") {
        assertTrue(DraftUtils.looksLikeRefusal("I need the actual message to help you"), "need actual")
        assertTrue(DraftUtils.looksLikeRefusal("I need more context to draft a reply"), "need context")
        assertTrue(DraftUtils.looksLikeRefusal("Could you provide the conversation?"), "could you provide")
        assertTrue(DraftUtils.looksLikeRefusal("I'd need to see the full thread"), "need to see")
        assertTrue(DraftUtils.looksLikeRefusal("Please provide the message content"), "please provide")
        assertTrue(DraftUtils.looksLikeRefusal("I can't write a reply without more info"), "can't write")
        assertTrue(DraftUtils.looksLikeRefusal("I don't have enough information"), "don't have enough")
    }

    runSuite("DraftUtils.looksLikeRefusal — case insensitivity") {
        assertTrue(DraftUtils.looksLikeRefusal("I NEED THE ACTUAL message"), "uppercase")
        assertTrue(DraftUtils.looksLikeRefusal("i need more context"), "lowercase")
        assertTrue(DraftUtils.looksLikeRefusal("Could You Provide the details?"), "mixed case")
    }

    runSuite("DraftUtils.looksLikeRefusal — new refusal phrases (contamination fix)") {
        assertTrue(DraftUtils.looksLikeRefusal("I'm ready to help! Go ahead and share the message"), "ready to help")
        assertTrue(DraftUtils.looksLikeRefusal("I don't see a conversation to respond to"), "no conversation")
        assertTrue(DraftUtils.looksLikeRefusal("The screenshot shows terminal output"), "screenshot shows")
        assertTrue(DraftUtils.looksLikeRefusal("Go ahead and share the message you need"), "go ahead share")
        assertTrue(DraftUtils.looksLikeRefusal("What did the person say that you're responding to?"), "what did person say")
        assertTrue(DraftUtils.looksLikeRefusal("Not a messaging conversation. Could you share the actual chat?"), "not messaging")
    }

    runSuite("DraftUtils.looksLikeRefusal — normal messages") {
        assertFalse(DraftUtils.looksLikeRefusal("Sure, I'll be there at 3pm"), "normal response")
        assertFalse(DraftUtils.looksLikeRefusal("Hey thanks for letting me know!"), "casual message")
        assertFalse(DraftUtils.looksLikeRefusal("Sounds good to me"), "short response")
        assertFalse(DraftUtils.looksLikeRefusal(""), "empty string")
        assertFalse(DraftUtils.looksLikeRefusal("Let me know what you need"), "contains 'need' but not a refusal phrase")
    }
}
