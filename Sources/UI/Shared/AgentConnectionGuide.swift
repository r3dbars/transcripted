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
    private static let codexInboxSetupFilename = "codex-inbox-setup.md"

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

    static var codexInboxFolder: URL {
        FileManager.default.transcriptedAppSupportDir
            .appendingPathComponent("CodexInbox", isDirectory: true)
            .standardizedFileURL
    }

    static var liveMeetingCodexFolder: URL {
        LiveMeetingCodexSession.defaultWorkspaceRoot
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

    static let liveMeetingCodexSkill = AgentConnectionStarterSkill(
        id: "transcripted-live-meeting",
        symbolName: "waveform",
        title: "Live Meeting",
        version: "0.2.1",
        detail: "Answer from a local live meeting sidecar in Codex or Cowork, then hand off to the final saved Markdown."
    )

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

    static let directToolNames = [
        "recent_context",
        "search_context",
        "list_meetings",
        "read_meeting",
        "list_dictations",
        "read_dictation",
        "search",
        "who_is",
        "recap",
    ]

    static func skillFileURL(for skill: AgentConnectionStarterSkill) -> URL {
        agentSkillsFolder.appendingPathComponent(skill.relativeSkillPath, isDirectory: false)
    }

    static func starterPrompt(filename: String?) -> String {
        let directToolsList = directToolNames
            .map { "- \($0)" }
            .joined(separator: "\n")
        var prompt = """
        I use Transcripted on this Mac.

        Use Transcripted direct tools first if they are connected:
        \(directToolsList)

        If direct tools are not connected, read my saved Transcripted Markdown files directly:

        Meetings:
        - \(meetingsFolder.path)

        Dictations:
        - \(dictationsFolder.path)

        Use these files as the source of truth.

        Rules:
        - Prefer Transcripted direct tools when available; otherwise search meetings and dictations together from files.
        - Cite filenames, dates, speakers, and timestamps when useful.
        - For relative dates like today or yesterday, state the exact dates searched.
        - If a direct tool fails, fall back to the folders.
        - If you cannot use direct tools or read a folder, say exactly what failed.
        - Do not suggest installing Claude Desktop or MCP unless I ask.
        """

        if let filename {
            prompt += "\n\nIf helpful, start with this meeting:\n\(filename).md"
        }

        return prompt
    }

    static func ensureCodexInboxFolder(
        appSupportRoot: URL? = nil,
        fileManager: FileManager = .default,
        createdAt: Date = Date()
    ) throws -> URL {
        let root = appSupportRoot ?? fileManager.transcriptedAppSupportDir
        let inboxURL = root
            .appendingPathComponent("CodexInbox", isDirectory: true)
            .standardizedFileURL

        try fileManager.createPrivateDirectory(at: inboxURL)
        for name in ["pending", "processed", "outputs", "state"] {
            try fileManager.createPrivateDirectory(at: inboxURL.appendingPathComponent(name, isDirectory: true))
        }

        try writeCodexInboxTextIfNeeded(readmeText(inboxURL: inboxURL), to: inboxURL.appendingPathComponent("README.md"), fileManager: fileManager)
        try writeCodexInboxTextIfNeeded(agentsText(inboxURL: inboxURL), to: inboxURL.appendingPathComponent("AGENTS.md"), fileManager: fileManager)
        try writeCodexInboxTextIfNeeded(
            codexInboxSetupPrompt(inboxURL: inboxURL),
            to: inboxURL.appendingPathComponent(codexInboxSetupFilename),
            fileManager: fileManager
        )

        let stateURL = inboxURL.appendingPathComponent("state.json", isDirectory: false)
        if !fileManager.fileExists(atPath: stateURL.path) {
            try initialCodexInboxState(createdAt: createdAt)
                .write(to: stateURL, atomically: true, encoding: .utf8)
            fileManager.restrictFileToOwnerOnly(at: stateURL)
        }

        return inboxURL
    }

    static func codexInboxSetupURL(inboxURL: URL = codexInboxFolder) -> URL? {
        var components = URLComponents()
        components.scheme = "codex"
        components.host = "threads"
        components.path = "/new"
        components.queryItems = [
            URLQueryItem(name: "path", value: inboxURL.standardizedFileURL.path),
            URLQueryItem(name: "prompt", value: codexInboxOpenPrompt(inboxURL: inboxURL)),
        ]
        return components.url
    }

    static func codexInboxSetupPrompt(inboxURL: URL = codexInboxFolder) -> String {
        let inboxPath = inboxURL.standardizedFileURL.path
        let setupPath = inboxURL
            .appendingPathComponent(codexInboxSetupFilename, isDirectory: false)
            .standardizedFileURL
            .path

        return """
        # Transcripted Codex Inbox Setup

        Set this Codex thread up as my Transcripted Inbox.

        Goal:
        When Transcripted saves a new meeting, check for it during work hours and post a short after-action report in this pinned Codex thread.

        Local paths:
        - Codex Inbox: \(inboxPath)
        - Setup prompt file: \(setupPath)
        - Meetings: \(meetingsFolder.path)
        - Dictations: \(dictationsFolder.path)
        - State file: \(inboxPath)/state.json
        - Pending folder: \(inboxPath)/pending
        - Processed folder: \(inboxPath)/processed
        - Outputs folder: \(inboxPath)/outputs

        Setup steps:
        1. Create or update a heartbeat automation named `transcripted-inbox-watch` attached to this Codex thread.
        2. Schedule it Monday through Friday from 8:05 AM through 5:35 PM local time, every 30 minutes at :05 and :35. If the scheduler cannot express that exactly, use the closest 30-minute weekday work-hours schedule and tell me what schedule you used.
        3. Ask me to pin this thread if it is not already pinned.
        4. Use `state.json` to avoid processing the same meeting twice.
        5. Treat the existing `installedAt` value in `state.json` as the baseline. Do not backfill older meetings unless I ask.

        Every heartbeat:
        - Never rely on the default current working directory.
        - Read `state.json`, `pending/`, `processed/`, and the Transcripted Meetings folder.
        - Find the newest unprocessed meeting saved after `installedAt`, or the oldest pending handoff if one exists.
        - If there is no new meeting, stay quiet.
        - If there is a new meeting, reply in this pinned thread with:
          1. What changed
          2. Short summary
          3. Decisions, if any
          4. What you owe
          5. What others owe you
          6. Useful follow-up drafts, if any
          7. The next 1-3 actions Codex can take
        - End with: `Want me to take any of these now? Reply with numbers.`
        - Ask before sending messages, creating issues, editing files outside this inbox, or taking external actions.
        - Keep it short and practical.
        """
    }

    static func codexInboxOpenPrompt(inboxURL: URL = codexInboxFolder) -> String {
        """
        Set up this thread as my Transcripted Codex Inbox. Read \(codexInboxSetupFilename) in this folder, create the heartbeat automation described there, and tell me what you set up.
        """
    }

    static func ensureLiveMeetingCodexWorkspace(
        appSupportRoot: URL? = nil,
        fileManager: FileManager = .default,
        createdAt: Date = Date()
    ) throws -> URL {
        let workspaceURL = (appSupportRoot ?? fileManager.transcriptedAppSupportDir)
            .appendingPathComponent(LiveMeetingCodexSession.workspaceFolderName, isDirectory: true)
            .standardizedFileURL
        let session = LiveMeetingCodexSession(workspaceRoot: workspaceURL, fileManager: fileManager)
        try session.ensureWorkspaceFiles(createdAt: createdAt)
        return workspaceURL
    }

    static func liveMeetingCodexSetupURL(workspaceURL: URL = liveMeetingCodexFolder) -> URL? {
        var components = URLComponents()
        components.scheme = "codex"
        components.host = "threads"
        components.path = "/new"
        components.queryItems = [
            URLQueryItem(name: "path", value: workspaceURL.standardizedFileURL.path),
            URLQueryItem(name: "prompt", value: liveMeetingCodexOpenPrompt(workspaceURL: workspaceURL)),
        ]
        return components.url
    }

    static func liveMeetingCodexSetupPrompt(workspaceURL: URL = liveMeetingCodexFolder) -> String {
        let session = LiveMeetingCodexSession(workspaceRoot: workspaceURL)
        return """
        # Transcripted Live Meeting Sidecar Setup

        Set this agent chat up as my live Transcripted meeting room.

        Local paths:
        - Workspace: \(workspaceURL.standardizedFileURL.path)
        - Setup prompt file: \(session.setupURL.path)
        - Live transcript: \(session.liveTranscriptURL.path)
        - State file: \(session.stateURL.path)
        - Handoff file: \(session.handoffURL.path)
        - Watcher state: \(session.watcherStateURL.path)
        - Preview: \(session.previewURL.path)
        - Codex browser preview: \(LiveMeetingCodexSession.previewServerURL.absoluteString)

        Rules:
        - Read `state.json` and `live_transcript.md` when I ask about the current meeting.
        - Treat live text as provisional and source-labeled.
        - Treat `[partial]` lines as live ASR hypotheses that may change.
        - If `finalTranscriptPath` exists in `state.json`, read that final Markdown and prefer it for speaker names, diarization, quotes, decisions, and durable notes.
        - Before waking me about a ready final transcript, check `agent-watcher-state.json`. Stay quiet if `lastHandledFinalTranscriptPath` already matches.
        - After handling a ready final transcript, update `agent-watcher-state.json` with that path and the current time.
        - Do not change Transcripted's normal meeting output.
        - Keep live answers short and say when the stream is too sparse to answer.
        - For a live transcript panel in Codex, open \(LiveMeetingCodexSession.previewServerURL.absoluteString) while Transcripted is running.

        Skill:
        - \(liveMeetingCodexSkill.title) v\(liveMeetingCodexSkill.version): \(skillFileURL(for: liveMeetingCodexSkill).path)
        """
    }

    static func liveMeetingCoworkSetupPrompt(workspaceURL: URL = liveMeetingCodexFolder) -> String {
        let session = LiveMeetingCodexSession(workspaceRoot: workspaceURL)
        return """
        # Transcripted Live Meeting Cowork Setup

        Use Claude Cowork as my live Transcripted meeting room.

        If you can access local folders, use this workspace:
        \(workspaceURL.standardizedFileURL.path)

        Start with:
        - \(session.setupURL.path)
        - \(session.stateURL.path)
        - \(session.liveTranscriptURL.path)
        - \(session.handoffURL.path)
        - \(session.watcherStateURL.path)
        - \(session.previewURL.path)

        Rules:
        - While `state.json` says `recording`, answer from `live_transcript.md`.
        - Treat live text as provisional. `[partial]` lines may change.
        - Preserve `[Microphone]` and `[System]` source labels when they matter.
        - If `finalTranscriptPath` exists or `agent-handoff.md` says `Status: ready`, use the final Markdown as the source of truth.
        - Before posting a post-meeting brief or waking me about the ready transcript, check `agent-watcher-state.json`. If `lastHandledFinalTranscriptPath` already matches, stay quiet unless I ask.
        - After handling a ready final transcript, update `agent-watcher-state.json` with the final path and current time.
        - Do not change Transcripted's normal meeting output.
        - If you cannot access the workspace folder, ask me to grant that folder or paste the current `live_transcript.md`.
        """
    }

    static func liveMeetingCodexOpenPrompt(workspaceURL: URL = liveMeetingCodexFolder) -> String {
        """
        Use this thread as my Transcripted Live Meeting room. Read \(LiveMeetingCodexSession.setupFilename) in this folder and tell me when you are ready to watch the live transcript.
        """
    }

    static var folderAccessPrompt: String {
        """
        I use Transcripted on my Mac.

        This is fallback setup for a web chat or Cowork session that cannot use the live sidecar folder.

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
        mcpConfigExampleText(commandPath: ClaudeDesktopIntegrationInstaller.installedMCPBinaryURL.path)
    }

    static func mcpConfigExampleText(commandPath: String) -> String {
        ClaudeDesktopIntegrationInstaller.configSnippet(commandPath: commandPath)
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

    static var folderPathsText: String {
        """
        Meetings:
        \(meetingsFolder.path)

        Dictations:
        \(dictationsFolder.path)
        """
    }

    private static func readmeText(inboxURL: URL) -> String {
        """
        # Transcripted Codex Inbox

        This folder helps Codex watch Transcripted's local meeting Markdown files and turn new meetings into follow-up work.

        Start here:
        - `codex-inbox-setup.md` tells Codex how to create the recurring pinned-thread check.
        - `state.json` tracks the setup baseline and processed meetings.
        - `pending/` is for future Transcripted handoffs.
        - `processed/` is for meetings Codex has already handled.
        - `outputs/` is for after-action reports or drafts Codex writes back.

        Transcripted meeting files live at:
        \(meetingsFolder.path)

        Codex Inbox:
        \(inboxURL.standardizedFileURL.path)
        """
    }

    private static func agentsText(inboxURL: URL) -> String {
        """
        # Transcripted Codex Inbox

        You are working in the user's Transcripted Codex Inbox.

        Start by reading:
        - `codex-inbox-setup.md`
        - `state.json`

        Use Transcripted's local Markdown meetings as the source of truth:
        - Meetings: \(meetingsFolder.path)
        - Dictations: \(dictationsFolder.path)

        Rules:
        - Process only new unprocessed meetings unless the user asks for backfill.
        - Do not invent facts.
        - Cite filenames, dates, speakers, and timestamps when useful.
        - Ask before sending messages, creating issues, editing files outside this inbox, or taking external actions.
        - Keep reports short and practical.

        Inbox path:
        \(inboxURL.standardizedFileURL.path)
        """
    }

    private static func initialCodexInboxState(createdAt: Date) -> String {
        let createdAtString = portableDateFormatter.string(from: createdAt)
        return """
        {
          "version": 1,
          "installedAt": "\(createdAtString)",
          "processedMeetings": []
        }
        """
    }

    private static func writeCodexInboxTextIfNeeded(
        _ text: String,
        to url: URL,
        fileManager: FileManager
    ) throws {
        if let existing = try? String(contentsOf: url, encoding: .utf8),
           existing == text {
            fileManager.restrictFileToOwnerOnly(at: url)
            return
        }

        try text.write(to: url, atomically: true, encoding: .utf8)
        fileManager.restrictFileToOwnerOnly(at: url)
    }
}
