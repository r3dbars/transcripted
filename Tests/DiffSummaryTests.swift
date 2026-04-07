// DiffSummaryTests.swift
// Tests for DiffSummary: word-level diff computation, edit description, milestones

func testDiffSummary() {

    // MARK: - computeWordDiff

    runSuite("DiffSummary.computeWordDiff — identical strings") {
        let ops = DiffSummary.computeWordDiff(original: "hello world", edited: "hello world")
        assertEqual(ops.count, 2, "should have 2 equal ops")
        assertEqual(ops[0], .equal("hello"), "first word equal")
        assertEqual(ops[1], .equal("world"), "second word equal")
    }

    runSuite("DiffSummary.computeWordDiff — deletion at start") {
        let ops = DiffSummary.computeWordDiff(original: "Hey there friend", edited: "there friend")
        assertTrue(ops.contains(.delete("Hey")), "should detect deletion of 'Hey'")
        assertTrue(ops.contains(.equal("there")), "should have equal 'there'")
        assertTrue(ops.contains(.equal("friend")), "should have equal 'friend'")
    }

    runSuite("DiffSummary.computeWordDiff — insertion at end") {
        let ops = DiffSummary.computeWordDiff(original: "hello", edited: "hello world")
        assertTrue(ops.contains(.equal("hello")), "should have equal 'hello'")
        assertTrue(ops.contains(.insert("world")), "should detect insertion of 'world'")
    }

    runSuite("DiffSummary.computeWordDiff — replacement") {
        let ops = DiffSummary.computeWordDiff(original: "the quick fox", edited: "the slow fox")
        assertTrue(ops.contains(.equal("the")), "should have equal 'the'")
        assertTrue(ops.contains(.equal("fox")), "should have equal 'fox'")
        // 'quick' → 'slow' should be either a replace or a delete+insert
        let hasReplace = ops.contains(.replace(old: "quick", new: "slow"))
        let hasDeleteInsert = ops.contains(.delete("quick")) && ops.contains(.insert("slow"))
        assertTrue(hasReplace || hasDeleteInsert, "should detect quick→slow change")
    }

    runSuite("DiffSummary.computeWordDiff — empty original") {
        let ops = DiffSummary.computeWordDiff(original: "", edited: "hello world")
        assertEqual(ops.count, 2, "should have 2 insert ops")
        assertEqual(ops[0], .insert("hello"), "first insert")
        assertEqual(ops[1], .insert("world"), "second insert")
    }

    runSuite("DiffSummary.computeWordDiff — empty edited") {
        let ops = DiffSummary.computeWordDiff(original: "hello world", edited: "")
        assertEqual(ops.count, 2, "should have 2 delete ops")
        assertEqual(ops[0], .delete("hello"), "first delete")
        assertEqual(ops[1], .delete("world"), "second delete")
    }

    runSuite("DiffSummary.computeWordDiff — both empty") {
        let ops = DiffSummary.computeWordDiff(original: "", edited: "")
        assertEqual(ops.count, 0, "should produce no ops")
    }

    runSuite("DiffSummary.computeWordDiff — mixed operations") {
        let ops = DiffSummary.computeWordDiff(
            original: "Hey Sarah! That sounds great, I'm in for lunch tomorrow.",
            edited: "hey! yeah totally down for lunch tmrw"
        )
        assertTrue(ops.count > 0, "should produce some ops")
        // With heavily-edited text, expect a mix of replaces, deletes, and equals
        let hasChanges = ops.contains(where: {
            if case .equal = $0 { return false }; return true
        })
        let hasEquals = ops.contains(where: {
            if case .equal = $0 { return true }; return false
        })
        assertTrue(hasChanges, "should have changes (deletes/inserts/replaces)")
        assertTrue(hasEquals, "should have some unchanged words (for, lunch)")
    }

    // MARK: - describeEdit

    runSuite("DiffSummary.describeEdit — shortened significantly") {
        let desc = DiffSummary.describeEdit(
            original: "Hey there! That sounds absolutely wonderful, I would love to join you for lunch tomorrow if you are free.",
            edited: "yeah down for lunch tmrw",
            platform: "slack"
        )
        assertTrue(desc.contains("shortened"), "should detect shortening: \(desc)")
    }

    runSuite("DiffSummary.describeEdit — expanded significantly") {
        let desc = DiffSummary.describeEdit(
            original: "sounds good",
            edited: "That sounds really good to me! I was actually thinking the same thing and wanted to bring it up in our next meeting.",
            platform: "email"
        )
        assertTrue(desc.contains("expanded"), "should detect expansion: \(desc)")
    }

    runSuite("DiffSummary.describeEdit — minor tweaks") {
        let desc = DiffSummary.describeEdit(
            original: "Hey, sounds good for lunch tomorrow!",
            edited: "Hey, sounds good for lunch tomorrow.",
            platform: "imessage"
        )
        assertTrue(desc.contains("minor") || desc.contains("tweak"), "should detect minor changes: \(desc)")
    }

    runSuite("DiffSummary.describeEdit — includes platform") {
        let desc = DiffSummary.describeEdit(
            original: "Hello there!",
            edited: "yo!",
            platform: "slack"
        )
        assertTrue(desc.contains("Slack"), "should include platform name: \(desc)")
    }

    runSuite("DiffSummary.describeEdit — generic platform omitted") {
        let desc = DiffSummary.describeEdit(
            original: "Hello there!",
            edited: "yo!",
            platform: "generic"
        )
        assertFalse(desc.contains("Generic"), "should not include generic platform: \(desc)")
    }

    // MARK: - hasSubstantiveEdits

    runSuite("DiffSummary.hasSubstantiveEdits — identical") {
        assertFalse(DiffSummary.hasSubstantiveEdits(original: "hello world", edited: "hello world"), "identical should be false")
    }

    runSuite("DiffSummary.hasSubstantiveEdits — whitespace only") {
        assertFalse(DiffSummary.hasSubstantiveEdits(original: "hello  world", edited: "hello world"), "whitespace diff should be false")
    }

    runSuite("DiffSummary.hasSubstantiveEdits — case difference") {
        assertFalse(DiffSummary.hasSubstantiveEdits(original: "Hello World", edited: "hello world"), "case diff should be false")
    }

    runSuite("DiffSummary.hasSubstantiveEdits — real edit") {
        assertTrue(DiffSummary.hasSubstantiveEdits(original: "hello world", edited: "hello earth"), "word change should be true")
    }

    // MARK: - milestoneMessage

    runSuite("DiffSummary.milestoneMessage — milestone counts") {
        assertNotNil(DiffSummary.milestoneMessage(exampleCount: 5), "5 is a milestone")
        assertNotNil(DiffSummary.milestoneMessage(exampleCount: 10), "10 is a milestone")
        assertNotNil(DiffSummary.milestoneMessage(exampleCount: 20), "20 is a milestone")
        assertNotNil(DiffSummary.milestoneMessage(exampleCount: 50), "50 is a milestone")
        assertNotNil(DiffSummary.milestoneMessage(exampleCount: 100), "100 is a milestone")
    }

    runSuite("DiffSummary.milestoneMessage — non-milestones") {
        assertNil(DiffSummary.milestoneMessage(exampleCount: 1), "1 is not a milestone")
        assertNil(DiffSummary.milestoneMessage(exampleCount: 7), "7 is not a milestone")
        assertNil(DiffSummary.milestoneMessage(exampleCount: 25), "25 is not a milestone")
        assertNil(DiffSummary.milestoneMessage(exampleCount: 99), "99 is not a milestone")
    }
}
