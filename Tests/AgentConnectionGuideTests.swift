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

    runSuite("AgentConnectionGuide.starterPrompt — keeps the local agent path simple") {
        let prompt = AgentConnectionGuide.starterPrompt(filename: "Planning Sync")

        assertTrue(
            prompt.contains("Use Transcripted direct tools first if they are connected:"),
            "prompt should tell local agents to use direct tools when available"
        )
        assertTrue(
            prompt.contains("recent_context") && prompt.contains("search_context") && prompt.contains("read_meeting"),
            "prompt should name the main Transcripted direct tools"
        )
        assertTrue(
            prompt.contains("If direct tools are not connected, read my saved Transcripted Markdown files directly:"),
            "prompt should keep saved Markdown as the fallback path"
        )
        assertTrue(
            !prompt.contains("Install for Claude Desktop"),
            "local agent prompt should not route users through Claude Desktop setup"
        )
        assertTrue(
            !prompt.contains("web chat") && !prompt.contains("Cowork"),
            "local agent prompt should not include web/Cowork routing"
        )
        assertTrue(
            prompt.contains("Prefer Transcripted direct tools when available; otherwise search meetings and dictations together from files."),
            "prompt should support direct-tool retrieval and folder fallback"
        )
        assertTrue(
            prompt.contains("For relative dates like today or yesterday, state the exact dates searched."),
            "prompt should force exact dates for relative-date work"
        )
        assertTrue(
            prompt.contains("If a direct tool fails, fall back to the folders."),
            "prompt should recover from direct-tool failures"
        )
        assertTrue(
            prompt.contains("If you cannot use direct tools or read a folder, say exactly what failed."),
            "prompt should name the failed access path when blocked"
        )
        assertTrue(
            prompt.contains("Do not suggest installing Claude Desktop or MCP unless I ask."),
            "prompt should avoid pushing setup work unless the user asks"
        )
        assertTrue(
            prompt.contains("Meetings:\n- \(AgentConnectionGuide.meetingsFolder.path)"),
            "prompt should include the meetings folder"
        )
        assertTrue(
            prompt.contains("Dictations:\n- \(AgentConnectionGuide.dictationsFolder.path)"),
            "prompt should include the dictations folder"
        )
        assertTrue(
            prompt.contains("If helpful, start with this meeting:\nPlanning Sync.md"),
            "meeting-specific prompt should preserve the selected filename"
        )
    }

    runSuite("AgentConnectionGuide.folderAccessPrompt — marks web setup as fallback") {
        let prompt = AgentConnectionGuide.folderAccessPrompt

        assertTrue(
            prompt.contains("fallback setup for a web chat or Cowork session"),
            "folder prompt should be explicit that web chat setup is fallback only"
        )
        assertTrue(
            prompt.contains("Use those granted folders first."),
            "folder prompt should prefer folders granted in the current chat"
        )
        assertTrue(
            prompt.contains("tell me exactly which folder is missing"),
            "folder prompt should ask for a precise missing folder instead of guessing"
        )
    }

    runSuite("AgentConnectionGuide.mcpSetupText — avoids source-build instructions for DMG users") {
        let setupText = AgentConnectionGuide.mcpSetupText

        assertTrue(
            setupText.contains("Open Transcripted Settings."),
            "Claude Desktop setup should start inside the app"
        )
        assertTrue(
            setupText.contains("Click Install for Claude Desktop."),
            "Claude Desktop setup should use the in-app installer"
        )
        assertTrue(
            setupText.contains(ClaudeDesktopIntegrationInstaller.installedMCPBinaryURL.path),
            "Claude Desktop setup should show the stable installed helper path"
        )
        assertTrue(
            !setupText.contains("swift build"),
            "DMG setup copy should not ask normal users to build from source"
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
