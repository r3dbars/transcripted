// CapturedContextTests.swift
// Tests for CapturedContext.parse(), displayText, draftingPrompt()

func testCapturedContext() {
    runSuite("CapturedContext.parse") {
        // Basic labeled sections
        let input = """
            PLATFORM: Slack
            TALKING TO: Sarah Graham
            FORMALITY: casual

            CONVERSATION:
            Sarah: Hey, are you coming to lunch?
            Justin: Let me check my calendar
            """
        let ctx = CapturedContext.parse(from: input)
        assertEqual(ctx.platform, "slack", "platform should be lowercase")
        assertEqual(ctx.talkingTo, "Sarah Graham", "talkingTo")
        assertEqual(ctx.formality, "casual", "formality")
        assertTrue(ctx.hasConversation, "should have conversation")
        assertEqual(ctx.conversation?.contains("Hey, are you coming"), true, "conversation content")
    }

    runSuite("CapturedContext.parse — case insensitivity") {
        let input = """
            platform: SLACK
            Talking To: Bob
            Formality: Professional
            conversation:
            Bob: Hello
            """
        let ctx = CapturedContext.parse(from: input)
        assertEqual(ctx.platform, "slack", "platform should be lowercased")
        assertEqual(ctx.talkingTo, "Bob")
        assertEqual(ctx.formality, "professional", "formality should be lowercased")
        assertTrue(ctx.hasConversation)
    }

    runSuite("CapturedContext.parse — empty input") {
        let ctx = CapturedContext.parse(from: "")
        assertNil(ctx.platform)
        assertNil(ctx.talkingTo)
        assertNil(ctx.formality)
        assertFalse(ctx.hasConversation)
    }

    runSuite("CapturedContext.parse — multi-line conversation") {
        let input = """
            PLATFORM: imessage
            CONVERSATION:
            Alice: Line 1
            Alice: Line 2
            Bob: Line 3
            """
        let ctx = CapturedContext.parse(from: input)
        assertEqual(ctx.platform, "imessage")
        let lines = ctx.conversation?.components(separatedBy: "\n").filter { !$0.isEmpty } ?? []
        assertEqual(lines.count, 3, "should have 3 conversation lines")
    }

    runSuite("CapturedContext.hasConversation — whitespace-only conversation") {
        var ctx = CapturedContext()
        ctx.conversation = "  \n  "

        assertFalse(ctx.hasConversation, "whitespace-only conversation should be treated as empty")
        assertFalse(ctx.displayText.contains("CONVERSATION:"), "display text should omit empty conversation sections")
        assertFalse(ctx.draftingPrompt(userInstructions: "").contains("CONVERSATION:"), "prompt should omit empty conversation sections")
    }

    runSuite("CapturedContext.parse — conversation stops at next header") {
        let input = """
            CONVERSATION:
            Alice: Hello
            PLATFORM: slack
            """
        let ctx = CapturedContext.parse(from: input)
        assertEqual(ctx.platform, "slack")
        // "Alice: Hello" should be the conversation (PLATFORM resets inConversation)
        assertFalse(ctx.conversation?.contains("slack") ?? false, "conversation should not contain platform line")
    }

    runSuite("CapturedContext.displayText") {
        var ctx = CapturedContext()
        ctx.platform = "slack"
        ctx.talkingTo = "Sarah"
        ctx.formality = "casual"
        ctx.conversation = "Sarah: Hi\nJustin: Hey"
        let display = ctx.displayText
        assertTrue(display.contains("PLATFORM: Slack"), "capitalized platform")
        assertTrue(display.contains("TALKING TO: Sarah"))
        assertTrue(display.contains("CONVERSATION:"))
    }

    runSuite("CapturedContext.draftingPrompt") {
        var ctx = CapturedContext()
        ctx.platform = "slack"
        ctx.talkingTo = "Sarah"
        ctx.conversation = "Sarah: Coming to lunch?"
        let prompt = ctx.draftingPrompt(userInstructions: "say yes")
        assertTrue(prompt.contains("PLATFORM: slack"))
        assertTrue(prompt.contains("TALKING TO: Sarah"))
        assertTrue(prompt.contains("Coming to lunch?"))
        assertTrue(prompt.contains("say yes"))
        assertTrue(prompt.contains("Write a reply"), "should include drafting instruction")
    }
}
