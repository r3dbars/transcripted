// InsightCardTests.swift
// Tests for InsightCard.from() factory method

func testInsightCard() {
    // MARK: - from() factory

    runSuite("InsightCard.from — valid complete input") {
        let input: [String: Any] = [
            "prompt_key": "ghostwriting_system",
            "saw": "Users consistently shorten greetings",
            "why": "Current prompt produces overly formal openings",
            "current_value": "Write a greeting...",
            "proposed_value": "Keep greetings brief and casual"
        ]
        let card = InsightCard.from(toolId: "tool_123", input: input)
        assertNotNil(card, "should create card from valid input")
        assertEqual(card!.promptKey, "ghostwriting_system")
        assertEqual(card!.saw, "Users consistently shorten greetings")
        assertEqual(card!.why, "Current prompt produces overly formal openings")
        assertEqual(card!.currentValue, "Write a greeting...")
        assertEqual(card!.proposedValue, "Keep greetings brief and casual")
        assertEqual(card!.suggestionId, "tool_123")
    }

    runSuite("InsightCard.from — missing prompt_key returns nil") {
        let input: [String: Any] = [
            "saw": "some evidence",
            "why": "some reason",
            "proposed_value": "new value"
        ]
        let card = InsightCard.from(toolId: "tool_456", input: input)
        assertNil(card, "missing prompt_key should return nil")
    }

    runSuite("InsightCard.from — minimal input (only prompt_key)") {
        let input: [String: Any] = [
            "prompt_key": "model"
        ]
        let card = InsightCard.from(toolId: "tool_789", input: input)
        assertNotNil(card, "should create card with just prompt_key")
        assertEqual(card!.promptKey, "model")
        assertEqual(card!.saw, "", "missing saw defaults to empty")
        assertEqual(card!.why, "", "missing why defaults to empty")
        assertEqual(card!.currentValue, "", "missing current_value defaults to empty")
        assertEqual(card!.proposedValue, "", "missing proposed_value defaults to empty")
    }

    runSuite("InsightCard.from — empty input") {
        let input: [String: Any] = [:]
        let card = InsightCard.from(toolId: "tool_empty", input: input)
        assertNil(card, "empty input should return nil")
    }

    runSuite("InsightCard.from — prompt_key is not a string") {
        let input: [String: Any] = [
            "prompt_key": 42,
            "proposed_value": "new value"
        ]
        let card = InsightCard.from(toolId: "tool_wrong_type", input: input)
        assertNil(card, "non-string prompt_key should return nil")
    }

    runSuite("InsightCard.from — changeDescription uses why field") {
        let input: [String: Any] = [
            "prompt_key": "drafting_system",
            "why": "The tone is too formal"
        ]
        let card = InsightCard.from(toolId: "tool_desc", input: input)
        assertNotNil(card)
        assertEqual(card!.changeDescription, "The tone is too formal", "changeDescription should equal why")
    }

    // MARK: - promptKeyLabel

    runSuite("InsightCard promptKeyLabel — known keys") {
        let keys = [
            ("drafting_system", "Drafting Prompt"),
            ("ghostwriting_system", "Ghostwriting Prompt"),
            ("context_extraction", "Vision Extraction"),
            ("style_analysis_early", "Style Analysis (Early)"),
            ("style_analysis_growing", "Style Analysis (Growing)"),
            ("style_analysis_mature", "Style Analysis (Mature)"),
            ("model", "Model"),
        ]
        for (key, expected) in keys {
            let card = InsightCard.from(toolId: "t", input: ["prompt_key": key])!
            assertEqual(card.promptKeyLabel, expected, "label for \(key)")
        }
    }

    runSuite("InsightCard promptKeyLabel — unknown key returns raw key") {
        let card = InsightCard.from(toolId: "t", input: ["prompt_key": "custom_prompt_xyz"])!
        assertEqual(card.promptKeyLabel, "custom_prompt_xyz", "unknown key returns itself")
    }

    runSuite("InsightCard.from — preserves toolId as suggestionId") {
        let card = InsightCard.from(toolId: "toolu_01ABC", input: ["prompt_key": "model"])!
        assertEqual(card.suggestionId, "toolu_01ABC")
    }
}
