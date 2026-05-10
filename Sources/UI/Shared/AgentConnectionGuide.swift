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
    private static let meetingContextDateFormatter: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
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

    static func starterPrompt(
        filename: String?,
        meetingTitle: String? = nil,
        meetingDate: Date? = nil
    ) -> String {
        var prompt = """
        I use Transcripted on this Mac.

        Read my saved Transcripted Markdown files directly:

        Meetings:
        - \(meetingsFolder.path)

        Dictations:
        - \(dictationsFolder.path)

        Use these files as the source of truth.

        Rules:
        - Search meetings and dictations together when useful.
        - Cite filenames, dates, speakers, and timestamps when useful.
        - For relative dates like today or yesterday, state the exact dates searched.
        - If you cannot read a folder, tell me which folder failed.
        - Do not suggest Claude Desktop or MCP unless I ask.
        """

        if let filename {
            prompt += "\n\nIf helpful, start with this meeting:\n- File: \(filename).md"
            if let meetingTitle, !meetingTitle.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                prompt += "\n- Title: \(meetingTitle)"
            }
            if let meetingDate {
                prompt += "\n- Recorded at: \(meetingContextDateFormatter.string(from: meetingDate))"
            }
        }

        return prompt
    }

    static var folderAccessPrompt: String {
        """
        I use Transcripted on my Mac.

        This is fallback setup for a web chat or Cowork session.

        I may have granted you access to my Transcripted folders in this chat. Use those granted folders first.

        Default folders:
        - Meetings: \(meetingsFolder.path)
        - Dictations: \(dictationsFolder.path)

        Read the Markdown files directly. If you cannot access the folders, tell me exactly which folder is missing and ask me to grant it.
        """
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
            "Transcripted direct tools setup:",
            "- Server name: transcripted",
            "- Transport: local stdio",
            "- Claude Desktop app flow: open Transcripted Settings > Agent, click Install for Claude Desktop, then restart Claude Desktop.",
            "- Installed command path after setup: \(ClaudeDesktopIntegrationInstaller.installedMCPBinaryURL.path)",
            "- Claude Desktop config path: \(ClaudeDesktopIntegrationInstaller.claudeDesktopConfigURL.path)",
        ]

        if let buildDirectory = localMCPBuildDirectory {
            lines.append("")
            lines.append("Developer source fallback:")
            lines.append("- Build directory: \(buildDirectory.path)")
            lines.append("- Build command: cd \(buildDirectory.path) && swift build -c release")
        }

        if let binary = localMCPBinary {
            lines.append("- Current app helper path: \(binary.path)")
        } else {
            lines.append("- If the helper is missing, ask me to install or update Transcripted, then use the in-app installer.")
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
        let command = ClaudeDesktopIntegrationInstaller.installedMCPBinaryURL.path
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
        [
            "Claude Desktop setup:",
            "1. Open Transcripted Settings.",
            "2. Go to Agent.",
            "3. Click Install for Claude Desktop.",
            "4. Restart Claude Desktop.",
            "",
            "Installed command path after setup:",
            "`\(ClaudeDesktopIntegrationInstaller.installedMCPBinaryURL.path)`",
        ].joined(separator: "\n")
    }

    static let folderPathsText = """
    Meetings:
    \(meetingsFolder.path)

    Dictations:
    \(dictationsFolder.path)
    """
}
