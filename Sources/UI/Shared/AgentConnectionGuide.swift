import Foundation

struct AgentConnectionStarterSkill {
    let id: String
    let symbolName: String
    let title: String
    let version: String
    let detail: String

    var relativeSkillPath: String {
        "\(id)/SKILL.md"
    }

    var displayDetail: String {
        detail
    }
}

enum AgentConnectionGuide {
    private static let portableDateFormatter: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter
    }()

    static var localMCPBuildDirectory: URL? {
        let bundleURL = Bundle.main.bundleURL.standardizedFileURL
        let buildDirectory = bundleURL.deletingLastPathComponent()
        let repoRoot = buildDirectory.deletingLastPathComponent()
        let toolsDirectory = repoRoot.appendingPathComponent("Tools/TranscriptedMCP", isDirectory: true)

        guard FileManager.default.fileExists(atPath: toolsDirectory.path) else {
            return nil
        }

        return toolsDirectory
    }

    static var localMCPBinary: URL? {
        let fileManager = FileManager.default

        if let bundledBinary = ClaudeDesktopIntegrationInstaller.bundledMCPBinaryURL(fileManager: fileManager) {
            return bundledBinary
        }

        let installedBinary = ClaudeDesktopIntegrationInstaller.installedMCPBinaryURL
        if fileManager.isExecutableFile(atPath: installedBinary.path) {
            return installedBinary
        }

        guard let buildDirectory = localMCPBuildDirectory else { return nil }
        let releaseBinary = buildDirectory
            .appendingPathComponent(".build", isDirectory: true)
            .appendingPathComponent("release", isDirectory: true)
            .appendingPathComponent("transcripted-mcp", isDirectory: false)

        if fileManager.isExecutableFile(atPath: releaseBinary.path) {
            return releaseBinary
        }

        let debugBinary = buildDirectory
            .appendingPathComponent(".build", isDirectory: true)
            .appendingPathComponent("debug", isDirectory: true)
            .appendingPathComponent("transcripted-mcp", isDirectory: false)

        return fileManager.isExecutableFile(atPath: debugBinary.path) ? debugBinary : nil
    }

    static var meetingsFolder: URL {
        MeetingStoragePaths.transcriptsFolder
    }

    static var dictationsFolder: URL {
        DictationStoragePaths.transcriptsFolder
    }

    static let starterSkills = [
        AgentConnectionStarterSkill(
            id: "transcripted-summarize",
            symbolName: "doc.text",
            title: "Summarize",
            version: "0.1.0",
            detail: "Create a cited brief from meetings, dictations, or a date range."
        ),
        AgentConnectionStarterSkill(
            id: "transcripted-search-memory",
            symbolName: "magnifyingglass",
            title: "Search Memory",
            version: "0.1.0",
            detail: "Find what was said, when it happened, and where it came from."
        ),
    ]

    static var agentSkillsFolder: URL {
        let fileManager = FileManager.default

        if let resourceURL = Bundle.main.resourceURL {
            let bundledURL = resourceURL.appendingPathComponent("AgentSkills", isDirectory: true)
            if fileManager.fileExists(atPath: bundledURL.path) {
                return bundledURL
            }
        }

        let repoURL = URL(fileURLWithPath: fileManager.currentDirectoryPath, isDirectory: true)
            .appendingPathComponent("Resources", isDirectory: true)
            .appendingPathComponent("AgentSkills", isDirectory: true)

        if fileManager.fileExists(atPath: repoURL.path) {
            return repoURL
        }

        return (Bundle.main.resourceURL ?? repoURL.deletingLastPathComponent())
            .appendingPathComponent("AgentSkills", isDirectory: true)
    }

    static var agentSkillsManifest: URL {
        agentSkillsFolder.appendingPathComponent("manifest.json", isDirectory: false)
    }

    static func skillFileURL(for skill: AgentConnectionStarterSkill) -> URL {
        agentSkillsFolder.appendingPathComponent(skill.relativeSkillPath, isDirectory: false)
    }

    static func starterPrompt(filename: String?) -> String {
        var prompt = """
        I use Transcripted on my Mac.

        Your job is to connect to my Transcripted data using the best available method, then help me search and summarize my meetings and dictations.

        Connection behavior:
        - Do not ask me to choose a connection mode.
        - Silently pick the best available route, then continue.
        - Only stop when you cannot read any Transcripted data. If that happens, give me one smallest next step.
        - If setup is needed, behave like a friendly setup concierge. Ask one short, natural question at a time.
        - Prefer plain language like "I found a working path" and "This chat cannot reach your Mac directly" over protocol or debug language.

        Automatic route priority:
        1. If Transcripted MCP tools are already available in this environment, use them first.
        2. If Transcripted MCP tools are not available, but this environment can build or configure a local MCP server, try to set up Transcripted MCP using the information below.
        3. If MCP cannot be used here, fall back to direct file access using the local folders below.
        4. If neither MCP nor folder access is possible, stop and tell me exactly what is missing, what you tried, and the smallest next step I need to take.

        Automatic environment routing:
        - Local agents running on this Mac, such as Codex, Claude Code in the terminal, Claude Code in an app, OpenCode, or OpenClaw, can usually read the local folders and bundled skill files. Use MCP when configured; otherwise use folder fallback.
        - Desktop clients with local stdio MCP support, such as Claude Desktop, can use Transcripted MCP after the MCP config is added and the client is restarted.
        - Remote or web chats, such as Claude chat in a browser, mobile chat, or any sandbox that cannot read `/Users/...` paths, cannot use local folders, local skill files, or local stdio MCP. Do not ask me to choose a mode. Say that this chat cannot reach my Mac directly, then ask me for the single smallest useful action: upload or paste captures, switch to a local agent, or use a remote connector if one is available.
        - Cowork or shared-agent environments may be local or remote. First determine whether the execution environment can read local Mac paths, then follow the matching rule above.

        Concierge setup style:
        - Start with "I'll check what I can use now."
        - If a route works, say "I found a working path" and keep going.
        - If direct tools are missing but folders work, say "We can use this now. Direct tools can be set up later."
        - If setup is truly needed, ask one question such as "Which app are you using: Claude Desktop, Claude Code, Codex, or something else?"
        - After the answer, give the exact next step for that app. Do not list every possible client.
        - Avoid acronyms unless needed. If you mention MCP, call it "Transcripted direct tools" first.

        \(mcpPromptBlock)

        Folder fallback:
        - Meetings: \(meetingsFolder.path)
        - Dictations: \(dictationsFolder.path)

        When using folders:
        - Read meeting and dictation markdown files directly.
        - Prefer the newest or most relevant meeting `.md` file when you need one meeting first.
        - Use exact filenames, dates, and speaker names when relevant.
        - Do not invent access or claim data you cannot read.

        Working rules:
        - Prefer MCP over raw file inspection when both are available.
        - Use meetings and dictations together when the task spans both.
        - Treat the raw transcript or dictation text as the source of truth.
        - Keep summaries and answers grounded in source filenames, dates, speakers, and timestamps when available.
        - Interpret relative dates in my local time zone. When I ask about today, yesterday, or last week, state the exact calendar dates you searched.
        - Surface uncertainty clearly.
        - If setup is needed, minimize back-and-forth and propose the next concrete action.

        Bundled starter skill files:
        \(starterSkillPromptBlock)

        Skill loading rules:
        - Before offering task options, check whether the manifest and bundled SKILL.md files above are readable.
        - If the files are readable, say "Bundled skills active" and list Summarize and Search Memory with their versions.
        - When I ask for Summarize or Search Memory behavior, open the matching SKILL.md before answering and treat it as the canonical behavior.
        - Use the skill versions above when giving feedback or suggesting improvements.
        - If you cannot read the skill files, say that clearly and use this fallback:
          - Summarize: create a cited brief from meetings, dictations, or a date range.
          - Search Memory: find what was said, when it happened, and where it came from.
        - If MCP setup requires restarting the agent, say so, then continue with folder fallback for the current session when folders are readable.

        First step:
        1. Silently determine which environment type you are in: local Mac agent, desktop MCP client, remote/web chat, or unknown cowork/shared context.
        2. Silently determine which connection mode is available: MCP, MCP setup, folders, uploaded/pasted files, or unavailable.
        3. Confirm whether the bundled SKILL.md files are readable.
        4. Briefly tell me the chosen route and active skill versions in natural language. Do not make me choose.
        5. Then continue with my task.
        """

        if let filename {
            prompt += "\n\nIf helpful, start with this meeting:\n\(filename).md"
        }

        return prompt
    }

    static var starterSkillPromptBlock: String {
        var lines = ["- Manifest: \(agentSkillsManifest.path)"]

        for skill in starterSkills {
            lines.append("- \(skill.title) v\(skill.version): \(skillFileURL(for: skill).path)")
        }

        return lines.joined(separator: "\n")
    }

    static func portableMeetingBundle(
        title: String,
        date: Date,
        transcriptURL: URL
    ) -> String? {
        guard let transcriptBody = MeetingTranscriptStyler.transcriptBody(at: transcriptURL),
              !transcriptBody.isEmpty else {
            return nil
        }

        let skillBlocks = starterSkills.map { skill in
            let skillText = (try? String(contentsOf: skillFileURL(for: skill), encoding: .utf8))?
                .trimmingCharacters(in: .whitespacesAndNewlines)
                ?? "\(skill.title): \(skill.detail)"

            return """
            <skill id="\(skill.id)" name="\(skill.title)" version="\(skill.version)">
            \(skillText)
            </skill>
            """
        }.joined(separator: "\n\n")

        return """
        I use Transcripted on my Mac.

        This is a portable Transcripted meeting bundle for any chat or agent. Use only the meeting content and embedded skills below. Do not claim access to my Mac, Transcripted MCP, or local folders unless this chat separately provides that access.

        Embedded skills:
        - Summarize v\(starterSkills[0].version)
        - Search Memory v\(starterSkills[1].version)

        Portable response rules:
        - If no task was included, ask one short question instead of analyzing the meeting: "I can read this Transcripted meeting bundle. I can summarize it, find decisions/action items, or search within it. What would you like?"
        - Do not critique tone, metaphors, writing style, usefulness, or what to ignore unless I explicitly ask for critique or opinion.
        - If I ask for a summary or recap, use the Summarize skill and include these sections when useful: Brief, Main Threads, Decisions, Action Items, Open Questions, Risks / Blockers, Worth Remembering, Sources, Uncertainty.
        - If I ask what was said, where something came from, or when something happened, use the Search Memory skill within this pasted meeting only.
        - Cite the source file and meeting date for important claims.

        Source:
        - Title: \(title)
        - Recorded at: \(portableDateFormatter.string(from: date))
        - Source file: \(transcriptURL.lastPathComponent)
        - Scope: this pasted meeting only

        \(skillBlocks)

        <meeting_transcript>
        \(transcriptBody)
        </meeting_transcript>
        """
    }

    static var mcpPromptBlock: String {
        var lines = [
            "Transcripted MCP setup:",
            "- Server name: transcripted",
            "- Transport: local stdio",
        ]

        if let buildDirectory = localMCPBuildDirectory {
            lines.append("- Build directory: \(buildDirectory.path)")
            lines.append("- Build command: cd \(buildDirectory.path) && swift build -c release")
        }

        if let binary = localMCPBinary {
            lines.append("- Expected binary: \(binary.path)")
            lines.append("")
            lines.append("Example MCP config:")
            lines.append("{")
            lines.append("  \"mcpServers\": {")
            lines.append("    \"transcripted\": {")
            lines.append("      \"command\": \"\(binary.path)\"")
            lines.append("    }")
            lines.append("  }")
            lines.append("}")
        } else {
            lines.append("- If a local transcripted-mcp binary is installed, add it to your MCP config under mcpServers.transcripted.command.")
        }

        lines.append("")
        lines.append("If connected, Transcripted MCP provides these read-only tools:")
        lines.append("- recent_context")
        lines.append("- search_context")
        lines.append("- list_meetings")
        lines.append("- read_meeting")
        lines.append("- list_dictations")
        lines.append("- read_dictation")
        lines.append("- search")
        lines.append("- who_is")
        lines.append("- recap")

        return lines.joined(separator: "\n")
    }

    static var mcpConfigExample: String {
        let command = localMCPBinary?.path ?? "/path/to/transcripted-mcp"
        return """
        {
          "mcpServers": {
            "transcripted": {
              "command": "\(command)"
            }
          }
        }
        """
    }

    static var mcpSetupText: String {
        var lines = [
            "MCP is optional. If your agent supports it, Transcripted can expose direct read-only tools for recent context, search, meetings, dictations, and recaps.",
            "",
            "For Claude Desktop, use Transcripted Settings > Agent > Install for Claude Desktop. Transcripted installs the read-only server, writes the config, checks your local library, then asks you to restart Claude Desktop.",
        ]

        if let binary = localMCPBinary {
            lines.append("")
            lines.append("Local binary:")
            lines.append("`\(binary.path)`")
        }

        if let buildDirectory = localMCPBuildDirectory {
            lines.append("")
            lines.append("Source build fallback:")
            lines.append("`cd \(buildDirectory.path) && swift build -c release`")
        }

        return lines.joined(separator: "\n")
    }

    static let folderPathsText = """
    Meetings:
    \(meetingsFolder.path)

    Dictations:
    \(dictationsFolder.path)
    """
}
