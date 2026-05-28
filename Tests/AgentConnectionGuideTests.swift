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
            AgentConnectionGuide.directToolNames.count == 9,
            "prompt should track the full Transcripted MCP direct tool set"
        )
        for toolName in AgentConnectionGuide.directToolNames {
            assertTrue(
                prompt.contains("- \(toolName)"),
                "prompt should name the \(toolName) direct tool"
            )
        }
        assertEqual(
            Set(AgentConnectionGuide.directToolNames),
            Set([
                "recent_context",
                "search_context",
                "list_meetings",
                "read_meeting",
                "list_dictations",
                "read_dictation",
                "search",
                "who_is",
                "recap",
            ]),
            "direct tool list should mirror Tools/TranscriptedMCP tool registration"
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

    runSuite("AgentConnectionGuide.codexInbox — creates the local setup folder") {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("TranscriptedCodexInbox-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let inbox = try? AgentConnectionGuide.ensureCodexInboxFolder(
            appSupportRoot: root,
            createdAt: Date(timeIntervalSince1970: 1_765_994_400)
        )

        assertNotNil(inbox, "Codex Inbox folder should be created")
        let inboxURL = inbox ?? root.appendingPathComponent("CodexInbox", isDirectory: true)
        assertEqual(inboxURL.lastPathComponent, "CodexInbox", "Codex Inbox should use a shell-friendly folder name")

        for name in ["pending", "processed", "outputs", "state"] {
            assertTrue(
                FileManager.default.fileExists(atPath: inboxURL.appendingPathComponent(name, isDirectory: true).path),
                "Codex Inbox should create \(name)/"
            )
        }

        let readme = (try? String(contentsOf: inboxURL.appendingPathComponent("README.md"), encoding: .utf8)) ?? ""
        let agents = (try? String(contentsOf: inboxURL.appendingPathComponent("AGENTS.md"), encoding: .utf8)) ?? ""
        let setup = (try? String(contentsOf: inboxURL.appendingPathComponent("codex-inbox-setup.md"), encoding: .utf8)) ?? ""
        let state = (try? String(contentsOf: inboxURL.appendingPathComponent("state.json"), encoding: .utf8)) ?? ""

        assertTrue(readme.contains("Transcripted Codex Inbox"), "README should name the Codex Inbox")
        assertTrue(agents.contains("Process only new unprocessed meetings"), "AGENTS should tell Codex not to backfill by default")
        assertTrue(setup.contains("transcripted-inbox-watch"), "setup prompt should name the heartbeat automation")
        assertTrue(state.contains("\"processedMeetings\": []"), "state should start with no processed meetings")
        assertTrue(state.contains("\"installedAt\""), "state should create a setup baseline")
    }

    runSuite("AgentConnectionGuide.codexInboxSetupPrompt — explains the pinned-thread automation") {
        let inboxURL = URL(fileURLWithPath: "/tmp/Transcripted Codex Inbox", isDirectory: true)
        let prompt = AgentConnectionGuide.codexInboxSetupPrompt(inboxURL: inboxURL)

        assertTrue(prompt.contains("Transcripted Codex Inbox Setup"), "prompt should title the setup clearly")
        assertTrue(prompt.contains(inboxURL.path), "prompt should include the inbox path")
        assertTrue(prompt.contains(AgentConnectionGuide.meetingsFolder.path), "prompt should include the meetings folder")
        assertTrue(prompt.contains("Monday through Friday"), "prompt should ask for a weekday schedule")
        assertTrue(prompt.contains(":05 and :35"), "prompt should ask for checks after the hour and half-hour")
        assertTrue(prompt.contains("stay quiet"), "prompt should keep empty checks silent")
        assertTrue(prompt.contains("Ask before sending messages"), "prompt should preserve approval before external action")
        assertFalse(prompt.contains("Claude Desktop"), "Codex setup should not route through Claude Desktop")
        assertFalse(prompt.contains("Justin"), "Codex setup should use user-neutral labels")
    }

    runSuite("AgentConnectionGuide.codexInboxSetupURL — opens a Codex thread with the inbox path") {
        let inboxURL = URL(fileURLWithPath: "/tmp/Transcripted Codex Inbox", isDirectory: true)
        let url = AgentConnectionGuide.codexInboxSetupURL(inboxURL: inboxURL)

        assertNotNil(url, "Codex setup should produce a deep link")
        let deepLink = url ?? URL(fileURLWithPath: "/")
        assertEqual(deepLink.scheme ?? "", "codex", "Codex setup should use the Codex URL scheme")
        assertEqual(deepLink.host ?? "", "threads", "Codex setup should open a thread")
        assertEqual(deepLink.path, "/new", "Codex setup should create a new thread")

        let queryItems = URLComponents(url: deepLink, resolvingAgainstBaseURL: false)?.queryItems ?? []
        let pathValue = queryItems.first { $0.name == "path" }?.value
        let promptValue = queryItems.first { $0.name == "prompt" }?.value ?? ""

        assertEqual(
            pathValue ?? "",
            inboxURL.standardizedFileURL.path,
            "Codex setup should pass the inbox as the thread working path"
        )
        assertTrue(
            promptValue.contains("codex-inbox-setup.md"),
            "Codex setup should keep the URL prompt short and point at the setup file"
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

    runSuite("AgentConnectionGuide.folderPathsText — stays computed from current storage paths") {
        let source = readAgentConnectionGuideSource()
        let folderText = AgentConnectionGuide.folderPathsText

        assertTrue(
            source.contains("static var folderPathsText"),
            "folder path copy should be computed so relocated capture-library paths are reflected"
        )
        assertTrue(folderText.contains(AgentConnectionGuide.meetingsFolder.path), "folder copy should include current meetings path")
        assertTrue(folderText.contains(AgentConnectionGuide.dictationsFolder.path), "folder copy should include current dictations path")
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
                "0.2.0",
                "skill manifest should expose the starter bundle version"
            )
            let skills = manifest["skills"] as? [[String: Any]] ?? []
            assertTrue(
                skills.contains { $0["id"] as? String == AgentConnectionGuide.liveMeetingCodexSkill.id },
                "skill manifest should include the live meeting skill"
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

        let liveSkill = AgentConnectionGuide.liveMeetingCodexSkill
        let liveSkillURL = skillsFolder.appendingPathComponent(liveSkill.relativeSkillPath, isDirectory: false)
        assertTrue(
            FileManager.default.fileExists(atPath: liveSkillURL.path),
            "expected bundled live meeting skill file"
        )
        let liveSkillText = (try? String(contentsOf: liveSkillURL, encoding: .utf8)) ?? ""
        assertTrue(
            liveSkillText.contains("Version: \(liveSkill.version)"),
            "live meeting skill file should carry the same version as UI metadata"
        )
        assertTrue(
            liveSkillText.contains("name: \(liveSkill.id)"),
            "live meeting skill file should use the same skill id as UI metadata"
        )
    }

    runSuite("AgentConnectionGuide.liveMeetingCodex - creates a live workspace and setup URL") {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("TranscriptedLiveMeetingCodexGuide-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let workspace = try? AgentConnectionGuide.ensureLiveMeetingCodexWorkspace(
            appSupportRoot: root,
            createdAt: Date(timeIntervalSince1970: 1_765_994_400)
        )
        let workspaceURL = workspace ?? root.appendingPathComponent(LiveMeetingCodexSession.workspaceFolderName, isDirectory: true)

        assertNotNil(workspace, "live meeting Codex workspace should be created")
        assertEqual(workspaceURL.lastPathComponent, "CodexLiveMeeting", "workspace should use a shell-friendly folder name")
        assertTrue(
            FileManager.default.fileExists(atPath: workspaceURL.appendingPathComponent("live_transcript.md").path),
            "live workspace should include live transcript file"
        )
        assertTrue(
            FileManager.default.fileExists(atPath: workspaceURL.appendingPathComponent("state.json").path),
            "live workspace should include state file"
        )

        let prompt = AgentConnectionGuide.liveMeetingCodexSetupPrompt(workspaceURL: workspaceURL)
        assertTrue(prompt.contains("Transcripted Live Meeting Codex Setup"), "prompt should name the live setup")
        assertTrue(prompt.contains("live_transcript.md"), "prompt should point Codex at the live transcript")
        assertTrue(prompt.contains("preview.html"), "prompt should point Codex at the live preview")
        assertTrue(prompt.contains(AgentConnectionGuide.liveMeetingCodexSkill.id), "prompt should name the live skill")
        assertTrue(prompt.contains("Do not change Transcripted's normal meeting output"), "prompt should preserve normal output")

        let url = AgentConnectionGuide.liveMeetingCodexSetupURL(workspaceURL: workspaceURL)
        assertNotNil(url, "live setup should produce a Codex deep link")
        let deepLink = url ?? URL(fileURLWithPath: "/")
        assertEqual(deepLink.scheme ?? "", "codex", "live setup should use the Codex URL scheme")
        assertEqual(deepLink.host ?? "", "threads", "live setup should open a thread")
        assertEqual(deepLink.path, "/new", "live setup should create a new thread")

        let queryItems = URLComponents(url: deepLink, resolvingAgainstBaseURL: false)?.queryItems ?? []
        assertEqual(
            queryItems.first { $0.name == "path" }?.value ?? "",
            workspaceURL.standardizedFileURL.path,
            "live setup should pass the workspace as the thread path"
        )
        assertTrue(
            queryItems.first { $0.name == "prompt" }?.value?.contains(LiveMeetingCodexSession.setupFilename) == true,
            "live setup prompt should point at the setup file"
        )
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

private func readAgentConnectionGuideSource() -> String {
    let url = URL(fileURLWithPath: FileManager.default.currentDirectoryPath, isDirectory: true)
        .appendingPathComponent("Sources/UI/Shared/AgentConnectionGuide.swift")
    return (try? String(contentsOf: url, encoding: .utf8)) ?? ""
}
