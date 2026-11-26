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

}

enum AgentConnectionGuide {
    // Keep formatter state local to each call while preserving millisecond rounding.
    private static func portableDateString(_ date: Date) -> String {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter.string(from: date)
    }

    /// The public docs for transcribing files from Terminal, linked from the
    /// Agent page (it moved there with the retired Transcribe a file page).
    static let cliDocumentationURL = URL(string: "https://github.com/r3dbars/transcripted/blob/main/Tools/TranscriptedCLI/README.md")!

    static var meetingsFolder: URL {
        MeetingStoragePaths.transcriptsFolder
    }

    static var dictationsFolder: URL {
        DictationStoragePaths.transcriptsFolder
    }

    /// `<capture-library>/writing/`. The pure path form, so building a prompt
    /// never creates the folder for people who don't use Writing.
    static var writingFolder: URL {
        FileManager.writingDirectory(in: FileManager.default.transcriptedCaptureLibraryDir)
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

    static let directToolNames = [
        "list_meetings",
        "read_meeting",
        "list_dictations",
        "read_dictation",
        "list_writing",
        "read_writing",
        "search",
        "recent_context",
        "who_is",
        "status",
    ]

    static func skillFileURL(for skill: AgentConnectionStarterSkill) -> URL {
        agentSkillsFolder.appendingPathComponent(skill.relativeSkillPath, isDirectory: false)
    }

    /// The two tools a fresh agent should reach for first. The full set is
    /// `directToolNames`; an agent with the tools connected already sees them.
    static let starterToolNames = ["recent_context", "search"]

    static func starterPrompt(filename: String?) -> String {
        let starterTools = starterToolNames.joined(separator: " and ")
        var prompt = """
        I use Transcripted on this Mac.

        Use the Transcripted tools first if they are connected (start with \(starterTools)):
        - Meetings: list_meetings, read_meeting
        - Dictations: list_dictations, read_dictation
        - Writing (opt-in): list_writing, read_writing
        - Search & lookup: search, recent_context, who_is, status

        If direct tools are not connected, read my saved Transcripted Markdown files directly:

        Meetings:
        - \(meetingsFolder.path)

        Dictations:
        - \(dictationsFolder.path)

        Writing:
        - \(writingFolder.path)

        Use these files as the source of truth.

        Good first asks:
        - Summarize my latest meeting. Tell me which Transcripted source you used, including the filename/date, then list decisions and action items.
        - Review yesterday. Use recent_context or search to tell me what I promised, what changed, and what I should follow up on today.

        Rules:
        - Prefer Transcripted direct tools when available; otherwise search meetings, dictations, and writing together from files.
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
        - Recorded at: \(portableDateString(date))
        - Source file: \(transcriptURL.lastPathComponent)
        - Scope: this pasted meeting only

        \(skillBlocks)

        <meeting_transcript>
        \(transcriptBody)
        </meeting_transcript>
        """
    }

    static var folderPathsText: String {
        """
        Meetings:
        \(meetingsFolder.path)

        Dictations:
        \(dictationsFolder.path)

        Writing:
        \(writingFolder.path)
        """
    }
}
