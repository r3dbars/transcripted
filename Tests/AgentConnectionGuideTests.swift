import Foundation

func testAgentConnectionGuide() {
    runSuite("AgentConnectionGuide.starterSkills — exposes the two starter skills") {
        let skills = AgentConnectionGuide.starterSkills

        assertEqual(skills.count, 2, "connect-agent should ship two starter skills")
        assertEqual(skills[0].title, "Summarize", "first starter skill should be Summarize")
        assertEqual(skills[1].title, "Search Memory", "second starter skill should be Search Memory")
        assertEqual(skills[0].version, "0.1.0", "Summarize should expose its shipped version")
        assertEqual(skills[1].version, "0.1.0", "Search Memory should expose its shipped version")
        assertTrue(
            skills[0].displayDetail.lowercased().contains("cited brief"),
            "Summarize copy should promise cited briefs"
        )
        assertTrue(
            skills[1].displayDetail.lowercased().contains("where it came from"),
            "Search Memory copy should promise source traceability"
        )
    }

    runSuite("AgentConnectionGuide.starterPrompt — points to bundled skill files") {
        let prompt = AgentConnectionGuide.starterPrompt(filename: "Planning Sync")

        assertTrue(prompt.contains("Bundled starter skill files:"), "prompt should include bundled skill section")
        assertTrue(prompt.contains("Manifest:"), "prompt should point to the skill manifest")
        assertTrue(prompt.contains("transcripted-summarize/SKILL.md"), "prompt should include Summarize skill file")
        assertTrue(prompt.contains("transcripted-search-memory/SKILL.md"), "prompt should include Search Memory skill file")
        assertTrue(prompt.contains("Summarize v0.1.0"), "prompt should include Summarize version")
        assertTrue(prompt.contains("Search Memory v0.1.0"), "prompt should include Search Memory version")
        assertTrue(
            prompt.contains("Treat the raw transcript or dictation text as the source of truth."),
            "prompt should ground answers in raw captures"
        )
        assertTrue(
            prompt.contains("When your environment can read local files, open the relevant SKILL.md file above"),
            "prompt should make SKILL.md files canonical"
        )
        assertTrue(
            prompt.contains("If helpful, start with this meeting:\nPlanning Sync.md"),
            "meeting-specific prompt should preserve the selected filename"
        )
    }

    runSuite("AgentConnectionGuide bundled skills — files and manifest are versioned") {
        let skillsFolder = URL(fileURLWithPath: FileManager.default.currentDirectoryPath, isDirectory: true)
            .appendingPathComponent("Resources", isDirectory: true)
            .appendingPathComponent("AgentSkills", isDirectory: true)
        let manifestURL = skillsFolder.appendingPathComponent("manifest.json", isDirectory: false)

        assertTrue(
            FileManager.default.fileExists(atPath: manifestURL.path),
            "agent skill manifest should exist in app resources"
        )

        if let manifestData = try? Data(contentsOf: manifestURL),
           let manifest = try? JSONSerialization.jsonObject(with: manifestData) as? [String: Any] {
            assertEqual(
                manifest["bundle_version"] as? String,
                "0.1.0",
                "skill manifest should expose the starter bundle version"
            )
        } else {
            assertTrue(false, "skill manifest should be readable JSON")
        }

        for skill in AgentConnectionGuide.starterSkills {
            let skillURL = skillsFolder.appendingPathComponent(skill.relativeSkillPath, isDirectory: false)

            assertTrue(
                FileManager.default.fileExists(atPath: skillURL.path),
                "expected bundled skill file: \(skill.relativeSkillPath)"
            )

            let skillText = (try? String(contentsOf: skillURL, encoding: .utf8)) ?? ""
            assertTrue(
                skillText.contains("Version: \(skill.version)"),
                "skill file should carry the same version as UI metadata: \(skill.id)"
            )
            assertTrue(
                skillText.contains("name: \(skill.id)"),
                "skill file should use the same skill id as UI metadata: \(skill.id)"
            )
        }
    }
}
