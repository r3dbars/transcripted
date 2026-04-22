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
            prompt.contains("Automatic environment routing:"),
            "prompt should include environment-specific routing guidance"
        )
        assertTrue(
            prompt.contains("Do not ask me to choose a connection mode."),
            "prompt should keep routing decisions away from the user"
        )
        assertTrue(
            prompt.contains("behave like a friendly setup concierge"),
            "prompt should request concierge-style setup behavior"
        )
        assertTrue(
            prompt.contains("Ask one short, natural question at a time."),
            "prompt should avoid dumping setup choices"
        )
        assertTrue(
            prompt.contains("Local agents running on this Mac, such as Codex, Claude Code in the terminal"),
            "prompt should name local agent contexts"
        )
        assertTrue(
            prompt.contains("Remote or web chats, such as Claude chat in a browser"),
            "prompt should explain remote chat limitations"
        )
        assertTrue(
            prompt.contains("If I granted folders in Cowork, use those folders before deciding Transcripted has no data."),
            "prompt should prefer user-granted Cowork folders before declaring Transcripted empty"
        )
        assertTrue(
            prompt.contains("Concierge setup style:"),
            "prompt should include natural setup behavior guidance"
        )
        assertTrue(
            prompt.contains("If a route works, say \"I found a working path\" and keep going."),
            "prompt should keep working when any usable route exists"
        )
        assertTrue(
            prompt.contains("Which app are you using: Claude Desktop, Claude Code, Codex, or something else?"),
            "prompt should ask one natural setup question when blocked"
        )
        assertTrue(
            prompt.contains("Treat the raw transcript or dictation text as the source of truth."),
            "prompt should ground answers in raw captures"
        )
        assertTrue(
            prompt.contains("If you cannot read the skill files, do not treat that as a setup failure."),
            "prompt should treat unreadable skill files as optional fallback, not a setup failure"
        )
        assertTrue(
            prompt.contains("When I ask for Summarize or Search Memory behavior, open the matching SKILL.md before answering"),
            "prompt should make SKILL.md files canonical for matching tasks"
        )
        assertTrue(
            prompt.contains("Briefly tell me the chosen route in natural language."),
            "prompt should report the chosen route without making the user choose"
        )
        assertTrue(
            prompt.contains("Do not ask me to build Transcripted MCP from source for a normal DMG install."),
            "prompt should route Claude Desktop users through the DMG-installed app flow"
        )
        assertTrue(
            prompt.contains("Check user-granted folders before checking the default paths."),
            "prompt should use granted folders before default Transcripted paths"
        )
        assertTrue(
            prompt.contains("continue with folder fallback for the current session when folders are readable"),
            "prompt should keep Claude Code moving when MCP setup needs restart"
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

    runSuite("AgentConnectionGuide.portableMeetingBundle — embeds meeting and skills for any chat") {
        let meetingURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("TranscriptedAgentBundleTests-\(UUID().uuidString).md")
        defer { try? FileManager.default.removeItem(at: meetingURL) }

        let meetingMarkdown = """
        ---
        title: "Launch Sync"
        date: "2026-04-18"
        time: "09:30:00"
        duration: "0:03"
        total_word_count: 12
        ---

        # Launch Sync

        ## Transcript

        **00:00**  [Speaker 1]
        We decided to ship the agent setup and copy for agent flow.
        """

        try? meetingMarkdown.write(to: meetingURL, atomically: true, encoding: .utf8)

        let bundle = AgentConnectionGuide.portableMeetingBundle(
            title: "Launch Sync",
            date: Date(timeIntervalSince1970: 1_765_994_400),
            transcriptURL: meetingURL
        )

        assertNotNil(bundle, "portable meeting bundle should be produced for readable meeting markdown")
        let text = bundle ?? ""
        assertTrue(text.contains("portable Transcripted meeting bundle"), "bundle should explain that it works in any chat")
        assertTrue(text.contains("transcripted-summarize"), "bundle should embed the Summarize skill")
        assertTrue(text.contains("transcripted-search-memory"), "bundle should embed the Search Memory skill")
        assertTrue(text.contains("Source file: \(meetingURL.lastPathComponent)"), "bundle should include source filename")
        assertTrue(
            text.contains("We decided to ship the agent setup and copy for agent flow."),
            "bundle should include the meeting transcript body"
        )
        assertTrue(
            text.contains("Do not claim access to my Mac"),
            "bundle should prevent remote chats from pretending they have local access"
        )
        assertTrue(
            text.contains("If no task was included, ask one short question"),
            "bundle should prevent pasted chats from summarizing before the user asks"
        )
        assertTrue(
            text.contains("Do not critique tone, metaphors, writing style"),
            "bundle should keep any-chat responses from turning into unsolicited critique"
        )
        assertTrue(
            text.contains("Brief, Main Threads, Decisions, Action Items"),
            "bundle should steer summaries into the embedded Summarize skill shape"
        )
        assertTrue(
            text.contains("use the Search Memory skill within this pasted meeting only"),
            "bundle should scope search-memory answers to the portable meeting"
        )
    }
}
