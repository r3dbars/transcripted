import Foundation
import TranscriptedCore

enum AgentConnectionGuide {
    static var meetingsFolder: URL {
        let url = MeetingStoragePaths.transcriptsFolder
        AgentOutput.writeAgentReadme(to: url)
        return url
    }

    static var dictationsFolder: URL {
        let url = DictationStoragePaths.transcriptsFolder
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    static let benefitHighlights = [
        "Search past meetings and dictations faster",
        "Pull summaries and action items in one place",
        "Give your agent the real spoken context from this Mac",
    ]

    static func starterPrompt(filename: String?) -> String {
        var prompt = """
        I use Transcripted on my Mac.

        If Transcripted MCP tools are available, use them first for recent context, search, meetings, dictations, and recaps.

        If Transcripted MCP tools are not available, use these local folders instead:

        Meetings:
        \(meetingsFolder.path)

        Dictations:
        \(dictationsFolder.path)

        If you use folders, read AGENT.md and transcripted.json in the meetings folder if they exist.

        Help me search, summarize, and organize my local meetings and dictations.

        If neither MCP nor folder access is available yet, help me set up the best option and then continue.
        """

        if let filename {
            prompt += "\n\nIf helpful, start with this meeting:\n\(filename).json"
        }

        return prompt
    }

    static let mcpConfigExample = """
    {
      "mcpServers": {
        "transcripted": {
          "command": "/path/to/transcripted-mcp"
        }
      }
    }
    """

    static let mcpSetupText = """
    MCP is optional. If your agent supports it, Transcripted can expose direct read-only tools for recent context, search, meetings, dictations, and recaps.

    Install the read-only `transcripted-mcp` server, add it to your MCP config, then restart your client. The server reads the same local Transcripted data automatically.
    """

    static let folderPathsText = """
    Meetings:
    \(meetingsFolder.path)

    Dictations:
    \(dictationsFolder.path)
    """
}
