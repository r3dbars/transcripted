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
        "v\(version) - \(detail)"
    }
}

enum AgentConnectionGuide {
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
        guard let buildDirectory = localMCPBuildDirectory else { return nil }
        let binary = buildDirectory
            .appendingPathComponent(".build", isDirectory: true)
            .appendingPathComponent("debug", isDirectory: true)
            .appendingPathComponent("transcripted-mcp", isDirectory: false)

        return FileManager.default.fileExists(atPath: binary.path) ? binary : nil
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

        Connection priority:
        1. If Transcripted MCP tools are already available in this environment, use them first.
        2. If Transcripted MCP tools are not available, but this environment can build or configure a local MCP server, try to set up Transcripted MCP using the information below.
        3. If MCP cannot be used here, fall back to direct file access using the local folders below.
        4. If neither MCP nor folder access is possible, stop and tell me exactly what is missing, what you tried, and the smallest next step I need to take.

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
        - When your environment can read local files, open the relevant SKILL.md file above and treat it as the canonical behavior.
        - Use the skill versions above when giving feedback or suggesting improvements.
        - If you cannot read the skill files, say that clearly and use this fallback:
          - Summarize: create a cited brief from meetings, dictations, or a date range.
          - Search Memory: find what was said, when it happened, and where it came from.

        First step:
        Determine which connection mode is available: MCP, MCP setup, or folders.
        Briefly tell me which mode you are using, then continue with my task.
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

    static var mcpPromptBlock: String {
        var lines = [
            "Transcripted MCP setup:",
            "- Server name: transcripted",
            "- Transport: local stdio",
        ]

        if let buildDirectory = localMCPBuildDirectory {
            lines.append("- Build directory: \(buildDirectory.path)")
            lines.append("- Build command: cd \(buildDirectory.path) && swift build")
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
            "Install the read-only `transcripted-mcp` server, add it to your MCP config, then restart your client. The server reads the same local Transcripted data automatically.",
        ]

        if let buildDirectory = localMCPBuildDirectory {
            lines.append("")
            lines.append("Local build directory:")
            lines.append("`\(buildDirectory.path)`")
        }

        if let binary = localMCPBinary {
            lines.append("")
            lines.append("Local binary:")
            lines.append("`\(binary.path)`")
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
