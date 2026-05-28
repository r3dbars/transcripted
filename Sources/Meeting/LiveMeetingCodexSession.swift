import Foundation

enum LiveMeetingCodexSource: String, Codable, Equatable {
    case microphone
    case system

    var markdownTag: String {
        switch self {
        case .microphone:
            return "[Microphone]"
        case .system:
            return "[System]"
        }
    }

    var displayName: String {
        switch self {
        case .microphone:
            return "Microphone"
        case .system:
            return "System audio"
        }
    }
}

struct LiveMeetingCodexTranscriptEntry: Codable, Equatable {
    let source: LiveMeetingCodexSource
    let text: String
    let timestampSeconds: TimeInterval
    let createdAt: Date

    init(
        source: LiveMeetingCodexSource,
        text: String,
        timestampSeconds: TimeInterval,
        createdAt: Date = Date()
    ) {
        self.source = source
        self.text = text
        self.timestampSeconds = timestampSeconds
        self.createdAt = createdAt
    }
}

enum LiveMeetingCodexSessionStatus: String, Codable, Equatable {
    case idle
    case recording
    case stopped
    case transcriptSaved = "transcript_saved"
    case cancelled
    case failed
}

struct LiveMeetingCodexState: Codable, Equatable {
    let version: Int
    var status: LiveMeetingCodexSessionStatus
    var title: String?
    var startedAt: Date?
    var updatedAt: Date
    var liveTranscriptPath: String
    var finalTranscriptPath: String?
    var streamingBackendStatus: String
    var note: String
}

final class LiveMeetingCodexSession {
    static let workspaceFolderName = "CodexLiveMeeting"
    static let liveTranscriptFilename = "live_transcript.md"
    static let stateFilename = "state.json"
    static let setupFilename = "codex-live-meeting.md"
    static let previewFilename = "preview.html"

    static var defaultWorkspaceRoot: URL {
        FileManager.default.transcriptedAppSupportDir
            .appendingPathComponent(workspaceFolderName, isDirectory: true)
            .standardizedFileURL
    }

    let workspaceRoot: URL
    private let fileManager: FileManager
    private var state: LiveMeetingCodexState

    init(
        workspaceRoot: URL = LiveMeetingCodexSession.defaultWorkspaceRoot,
        fileManager: FileManager = .default
    ) {
        self.workspaceRoot = workspaceRoot.standardizedFileURL
        self.fileManager = fileManager
        self.state = LiveMeetingCodexState(
            version: 1,
            status: .idle,
            title: nil,
            startedAt: nil,
            updatedAt: Date(timeIntervalSince1970: 0),
            liveTranscriptPath: workspaceRoot
                .appendingPathComponent(Self.liveTranscriptFilename, isDirectory: false)
                .standardizedFileURL
                .path,
            finalTranscriptPath: nil,
            streamingBackendStatus: "pending_local_streaming_asr_adapter",
            note: "Live Codex sidecar is ready. Final Transcripted meeting Markdown still saves normally after recording stops."
        )
    }

    var stateURL: URL {
        workspaceRoot.appendingPathComponent(Self.stateFilename, isDirectory: false)
    }

    var liveTranscriptURL: URL {
        workspaceRoot.appendingPathComponent(Self.liveTranscriptFilename, isDirectory: false)
    }

    var setupURL: URL {
        workspaceRoot.appendingPathComponent(Self.setupFilename, isDirectory: false)
    }

    var previewURL: URL {
        workspaceRoot.appendingPathComponent(Self.previewFilename, isDirectory: false)
    }

    func ensureWorkspaceFiles(createdAt: Date = Date()) throws {
        try fileManager.createPrivateDirectory(at: workspaceRoot)
        try writeTextIfChanged(readmeText(), to: workspaceRoot.appendingPathComponent("README.md", isDirectory: false))
        try writeTextIfChanged(agentsText(), to: workspaceRoot.appendingPathComponent("AGENTS.md", isDirectory: false))
        try writeTextIfChanged(setupText(), to: setupURL)
        try writeTextIfChanged(previewHTML(), to: previewURL)

        if !fileManager.fileExists(atPath: stateURL.path) {
            state.updatedAt = createdAt
            try writeState()
        }

        if !fileManager.fileExists(atPath: liveTranscriptURL.path) {
            try writeTextIfChanged(idleTranscriptText(), to: liveTranscriptURL)
        }
    }

    func start(title: String?, startedAt: Date = Date()) throws {
        try ensureWorkspaceFiles(createdAt: startedAt)

        state = LiveMeetingCodexState(
            version: 1,
            status: .recording,
            title: title,
            startedAt: startedAt,
            updatedAt: startedAt,
            liveTranscriptPath: liveTranscriptURL.standardizedFileURL.path,
            finalTranscriptPath: nil,
            streamingBackendStatus: "pending_local_streaming_asr_adapter",
            note: "This is a provisional live sidecar for Codex. The final Transcripted Markdown is written by the normal meeting pipeline."
        )

        try writeTextIfChanged(liveTranscriptHeader(title: title, startedAt: startedAt), to: liveTranscriptURL)
        try writeState()
    }

    func append(_ entry: LiveMeetingCodexTranscriptEntry) throws {
        let text = entry.text
            .replacingOccurrences(of: "\r", with: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }

        try ensureWorkspaceFiles()
        let line = "**\(Self.timestamp(entry.timestampSeconds))** \(entry.source.markdownTag) \(text)\n"
        try appendText(line, to: liveTranscriptURL)
        state.updatedAt = entry.createdAt
        try writeState()
    }

    func finish(status: LiveMeetingCodexSessionStatus = .stopped, at date: Date = Date()) throws {
        try ensureWorkspaceFiles(createdAt: date)
        state.status = status
        state.updatedAt = date
        switch status {
        case .stopped:
            state.note = "Recording stopped. Waiting for Transcripted to finish and save the final meeting Markdown."
            try appendText("\nRecording stopped. Waiting for final Transcripted transcript.\n", to: liveTranscriptURL)
        case .cancelled:
            state.note = "Recording cancelled. No final meeting transcript will be saved for this capture."
            try appendText("\nRecording cancelled. No final transcript will be saved for this capture.\n", to: liveTranscriptURL)
        case .failed:
            state.note = "Recording ended with an error. Check Transcripted for retry details."
            try appendText("\nRecording ended with an error. Check Transcripted for retry details.\n", to: liveTranscriptURL)
        case .idle, .recording, .transcriptSaved:
            break
        }
        try writeState()
    }

    func attachFinalTranscript(url: URL, title: String?, at date: Date = Date()) throws {
        try ensureWorkspaceFiles(createdAt: date)
        let transcriptPath = url.standardizedFileURL.path
        state.status = .transcriptSaved
        state.title = title ?? state.title
        state.updatedAt = date
        state.finalTranscriptPath = transcriptPath
        state.note = "Final Transcripted Markdown is ready. Prefer the final file for names, diarization, and durable notes."

        let titleLine: String
        if let title, !title.isEmpty {
            titleLine = "Title: \(title)\n"
        } else {
            titleLine = ""
        }
        let text = """

        Final Transcripted transcript is ready.
        \(titleLine)Path: \(transcriptPath)

        Prefer the final file for participant names, diarization, and durable meeting notes.
        """
        try appendText(text, to: liveTranscriptURL)
        try writeState()
    }

    private func writeState() throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        let data = try encoder.encode(state)
        try data.write(to: stateURL, options: .atomic)
        fileManager.restrictFileToOwnerOnly(at: stateURL)
    }

    private func writeTextIfChanged(_ text: String, to url: URL) throws {
        if let existing = try? String(contentsOf: url, encoding: .utf8),
           existing == text {
            fileManager.restrictFileToOwnerOnly(at: url)
            return
        }

        try text.write(to: url, atomically: true, encoding: .utf8)
        fileManager.restrictFileToOwnerOnly(at: url)
    }

    private func appendText(_ text: String, to url: URL) throws {
        if !fileManager.fileExists(atPath: url.path) {
            try writeTextIfChanged("", to: url)
        }

        let data = Data(text.utf8)
        let handle = try FileHandle(forWritingTo: url)
        defer { try? handle.close() }
        try handle.seekToEnd()
        try handle.write(contentsOf: data)
        fileManager.restrictFileToOwnerOnly(at: url)
    }

    private static func timestamp(_ seconds: TimeInterval) -> String {
        let totalSeconds = max(0, Int(seconds.rounded(.down)))
        let hours = totalSeconds / 3600
        let minutes = (totalSeconds % 3600) / 60
        let seconds = totalSeconds % 60

        if hours > 0 {
            return String(format: "%02d:%02d:%02d", hours, minutes, seconds)
        }

        return String(format: "%02d:%02d", minutes, seconds)
    }

    private func idleTranscriptText() -> String {
        """
        # Live Transcripted Meeting

        Status: idle

        Enable Live Meeting in Codex from Transcripted Settings > Agent, then start a meeting.
        Transcripted will still save the normal final meeting Markdown after recording stops.

        """
    }

    private func liveTranscriptHeader(title: String?, startedAt: Date) -> String {
        let titleLine: String
        if let title, !title.isEmpty {
            titleLine = "\nTitle: \(title)"
        } else {
            titleLine = ""
        }
        return """
        # Live Transcripted Meeting

        Status: recording\(titleLine)
        Started: \(Self.isoString(startedAt))

        This file is a provisional live sidecar for Codex.
        Transcripted still saves the normal final meeting Markdown after recording stops.
        Streaming backend: pending local Parakeet EOU adapter.

        ## Live Transcript

        """
    }

    private func readmeText() -> String {
        """
        # Transcripted Live Meeting for Codex

        This folder is a live sidecar workspace for an active Transcripted meeting.

        Files:
        - `live_transcript.md` is the provisional live transcript stream.
        - `state.json` says whether recording is active and where the final Transcripted Markdown lands.
        - `codex-live-meeting.md` is the setup prompt for a Codex thread.
        - `preview.html` is a small polling preview if you open this folder with a local web server.

        Important:
        - The live transcript is provisional.
        - The normal Transcripted meeting Markdown still saves in the capture library after stop.
        - Once `state.json` has `finalTranscriptPath`, prefer that final Markdown for names, diarization, and durable notes.

        Workspace:
        \(workspaceRoot.path)
        """
    }

    private func agentsText() -> String {
        """
        # Transcripted Live Meeting for Codex

        You are in a Transcripted live-meeting sidecar workspace.

        Start with:
        - `state.json`
        - `live_transcript.md`
        - `codex-live-meeting.md`

        Rules:
        - Treat `live_transcript.md` as provisional while `status` is `recording`.
        - Keep source labels like `[Microphone]` and `[System]` in mind.
        - If `state.json` has `finalTranscriptPath`, read that final Markdown and prefer it for participant names, diarization, quotes, decisions, and durable notes.
        - Do not change Transcripted's meeting files unless the user asks.
        - Keep live answers short. Say when the live stream is too sparse to answer.
        """
    }

    private func setupText() -> String {
        """
        # Transcripted Live Meeting Codex Setup

        Use this Codex thread as my live Transcripted meeting room.

        Local paths:
        - Workspace: \(workspaceRoot.path)
        - Live transcript: \(liveTranscriptURL.path)
        - State: \(stateURL.path)
        - Preview: \(previewURL.path)

        How to work:
        1. Read `state.json`.
        2. While status is `recording`, read `live_transcript.md` whenever I ask about the meeting.
        3. Treat live text as provisional and source-labeled.
        4. Once `finalTranscriptPath` is present, read that final Transcripted Markdown and prefer it for speaker names, diarization, and final notes.
        5. If I ask for a live view, open `preview.html` from this folder through a local HTTP server.

        Do not alter the normal Transcripted meeting output.
        """
    }

    private func previewHTML() -> String {
        """
        <!doctype html>
        <html lang="en">
        <head>
          <meta charset="utf-8">
          <meta name="viewport" content="width=device-width, initial-scale=1">
          <title>Transcripted Live Meeting</title>
          <style>
            :root { color-scheme: light dark; font-family: -apple-system, BlinkMacSystemFont, "Segoe UI", sans-serif; }
            body { margin: 0; padding: 24px; background: Canvas; color: CanvasText; }
            main { max-width: 880px; margin: 0 auto; }
            header { display: flex; align-items: center; justify-content: space-between; gap: 16px; margin-bottom: 18px; }
            h1 { font-size: 20px; margin: 0; }
            #status { font-size: 13px; opacity: 0.72; }
            pre { white-space: pre-wrap; word-wrap: break-word; font: 13px/1.55 ui-monospace, SFMono-Regular, Menlo, monospace; border: 1px solid color-mix(in srgb, CanvasText 16%, transparent); border-radius: 8px; padding: 16px; min-height: 68vh; }
          </style>
        </head>
        <body>
          <main>
            <header>
              <h1>Transcripted Live Meeting</h1>
              <div id="status">Loading...</div>
            </header>
            <pre id="transcript"></pre>
          </main>
          <script>
            async function refresh() {
              try {
                const [stateResponse, transcriptResponse] = await Promise.all([
                  fetch("state.json", { cache: "no-store" }),
                  fetch("live_transcript.md", { cache: "no-store" })
                ]);
                const state = await stateResponse.json();
                const transcript = await transcriptResponse.text();
                document.getElementById("status").textContent = `${state.status} - ${state.streamingBackendStatus}`;
                document.getElementById("transcript").textContent = transcript;
                window.scrollTo(0, document.body.scrollHeight);
              } catch (error) {
                document.getElementById("status").textContent = "Open through a local HTTP server to enable polling";
              }
            }
            refresh();
            setInterval(refresh, 1000);
          </script>
        </body>
        </html>
        """
    }

    private static func isoString(_ date: Date) -> String {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter.string(from: date)
    }
}
