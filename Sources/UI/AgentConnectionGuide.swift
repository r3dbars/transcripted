import Foundation
import TranscriptedCore

enum AgentConnectionGuide {
    static var appSupportFolder: URL {
        let url = FileManager.default.transcriptedAppSupportDir
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

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

    static let starterExamples = [
        "What did I miss in today's meetings?",
        "Find every time we discussed pricing or roadmap changes.",
        "Pull action items from my latest meeting and recent dictations.",
    ]

    static let mcpHighlights = [
        "Recent context across meetings and dictations",
        "Search by topic, date, or speaker",
        "Read one meeting or one dictation directly",
        "Look up a person with who_is",
        "Generate a recap for a day or week",
    ]

    static func starterPrompt(filename: String?) -> String {
        var prompt = """
        I use Transcripted on my Mac.

        Meetings folder:
        \(meetingsFolder.path)

        Dictations folder:
        \(dictationsFolder.path)

        Read AGENT.md and transcripted.json in the meetings folder if they exist.
        Then help me search, summarize, and organize my local meetings and dictations.
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
    For supported agents, install the read-only `transcripted-mcp` server and add it to your MCP config.

    Replace `/path/to/transcripted-mcp` with your installed server command, then restart your client.
    The server reads the same local Transcripted data automatically.
    """

    static let cliExamples = """
    transcripted-cli context-recent
    transcripted-cli context-search "roadmap"
    transcripted-cli read-dictation Dictations_YYYY-MM-DD
    transcripted-cli diarize /path/to/audio.wav --json
    """

    static let cliSummary = """
    Use the CLI when you want scripts, automation, or offline audio work.
    The context commands read the same local Transcripted folders as the app and MCP server.
    """
}
