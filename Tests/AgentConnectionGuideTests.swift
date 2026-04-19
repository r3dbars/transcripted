import Foundation

func testAgentConnectionGuide() {
    runSuite("AgentConnectionGuide.starterSkills — exposes the two starter skills") {
        let skills = AgentConnectionGuide.starterSkills

        assertEqual(skills.count, 2, "connect-agent should ship two starter skills")
        assertEqual(skills[0].title, "Summarize", "first starter skill should be Summarize")
        assertEqual(skills[1].title, "Search Memory", "second starter skill should be Search Memory")
        assertTrue(
            skills[0].detail.lowercased().contains("cited brief"),
            "Summarize copy should promise cited briefs"
        )
        assertTrue(
            skills[1].detail.lowercased().contains("where it came from"),
            "Search Memory copy should promise source traceability"
        )
    }

    runSuite("AgentConnectionGuide.starterPrompt — embeds skill playbooks") {
        let prompt = AgentConnectionGuide.starterPrompt(filename: "Planning Sync")

        assertTrue(prompt.contains("Starter skills:"), "prompt should include starter skill section")
        assertTrue(prompt.contains("1. Summarize"), "prompt should include Summarize skill")
        assertTrue(prompt.contains("2. Search Memory"), "prompt should include Search Memory skill")
        assertTrue(
            prompt.contains("Treat the raw transcript or dictation text as the source of truth."),
            "prompt should ground answers in raw captures"
        )
        assertTrue(
            prompt.contains("Do not invent owners, deadlines, decisions, or action items."),
            "Summarize should guard against invented action items"
        )
        assertTrue(
            prompt.contains("If nothing relevant is found, say \"not found\" and list what you searched."),
            "Search Memory should define the empty-result behavior"
        )
        assertTrue(
            prompt.contains("If helpful, start with this meeting:\nPlanning Sync.md"),
            "meeting-specific prompt should preserve the selected filename"
        )
    }
}
