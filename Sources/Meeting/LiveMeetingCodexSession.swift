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
    let isFinal: Bool

    init(
        source: LiveMeetingCodexSource,
        text: String,
        timestampSeconds: TimeInterval,
        createdAt: Date = Date(),
        isFinal: Bool = true
    ) {
        self.source = source
        self.text = text
        self.timestampSeconds = timestampSeconds
        self.createdAt = createdAt
        self.isFinal = isFinal
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
    static let previewServerPort: UInt16 = 47834
    static let previewServerPath = "/live-preview"

    static var previewServerURL: URL {
        URL(string: "http://127.0.0.1:\(previewServerPort)\(previewServerPath)")!
    }

    static var defaultWorkspaceRoot: URL {
        FileManager.default.transcriptedAppSupportDir
            .appendingPathComponent(workspaceFolderName, isDirectory: true)
            .standardizedFileURL
    }

    let workspaceRoot: URL
    private let fileManager: FileManager
    private let sessionLock = NSRecursiveLock()
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
        try withSessionLock {
            try ensureWorkspaceFilesLocked(createdAt: createdAt)
        }
    }

    private func ensureWorkspaceFilesLocked(createdAt: Date = Date()) throws {
        try fileManager.createPrivateDirectory(at: workspaceRoot)
        try writeTextIfChanged(readmeText(), to: workspaceRoot.appendingPathComponent("README.md", isDirectory: false))
        try writeTextIfChanged(agentsText(), to: workspaceRoot.appendingPathComponent("AGENTS.md", isDirectory: false))
        try writeTextIfChanged(setupText(), to: setupURL)

        if !fileManager.fileExists(atPath: stateURL.path) {
            state.updatedAt = createdAt
            try writeState()
        }

        if !fileManager.fileExists(atPath: liveTranscriptURL.path) {
            try writeTextIfChanged(idleTranscriptText(), to: liveTranscriptURL)
        }

        try writePreview()
    }

    func start(
        title: String?,
        startedAt: Date = Date(),
        streamingBackendStatus: String = "local_streaming_asr_initializing"
    ) throws {
        try withSessionLock {
            try ensureWorkspaceFilesLocked(createdAt: startedAt)

            state = LiveMeetingCodexState(
                version: 1,
                status: .recording,
                title: title,
                startedAt: startedAt,
                updatedAt: startedAt,
                liveTranscriptPath: liveTranscriptURL.standardizedFileURL.path,
                finalTranscriptPath: nil,
                streamingBackendStatus: streamingBackendStatus,
                note: "This is a provisional live sidecar for Codex. The final Transcripted Markdown is written by the normal meeting pipeline."
            )

            try writeTextIfChanged(liveTranscriptHeader(title: title, startedAt: startedAt), to: liveTranscriptURL)
            try writeState()
            try writePreview()
        }
    }

    func append(_ entry: LiveMeetingCodexTranscriptEntry) throws {
        try withSessionLock {
            let text = entry.text
                .replacingOccurrences(of: "\r", with: " ")
                .trimmingCharacters(in: .whitespacesAndNewlines)
            guard !text.isEmpty else { return }

            try ensureWorkspaceFilesLocked()
            let marker = entry.isFinal ? "" : " [partial]"
            let line = "**\(Self.timestamp(entry.timestampSeconds))** \(entry.source.markdownTag)\(marker) \(text)\n"
            try appendText(line, to: liveTranscriptURL)
            state.updatedAt = entry.createdAt
            try writeState()
            try writePreview()
        }
    }

    func finish(status: LiveMeetingCodexSessionStatus = .stopped, at date: Date = Date()) throws {
        try withSessionLock {
            try ensureWorkspaceFilesLocked(createdAt: date)
            state.status = status
            state.updatedAt = date
            switch status {
            case .stopped:
                state.streamingBackendStatus = "local_streaming_asr_stopped"
                state.note = "Recording stopped. Waiting for Transcripted to finish and save the final meeting Markdown."
                try appendText("\nRecording stopped. Waiting for final Transcripted transcript.\n", to: liveTranscriptURL)
            case .cancelled:
                state.streamingBackendStatus = "cancelled"
                state.note = "Recording cancelled. No final meeting transcript will be saved for this capture."
                try appendText("\nRecording cancelled. No final transcript will be saved for this capture.\n", to: liveTranscriptURL)
            case .failed:
                state.streamingBackendStatus = "failed"
                state.note = "Recording ended with an error. Check Transcripted for retry details."
                try appendText("\nRecording ended with an error. Check Transcripted for retry details.\n", to: liveTranscriptURL)
            case .idle, .recording, .transcriptSaved:
                break
            }
            try writeState()
            try writePreview()
        }
    }

    func attachFinalTranscript(url: URL, title: String?, at date: Date = Date()) throws {
        try withSessionLock {
            try ensureWorkspaceFilesLocked(createdAt: date)
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
            try writePreview()
        }
    }

    func updateStreamingBackendStatus(_ status: String, note: String? = nil, at date: Date = Date()) throws {
        try withSessionLock {
            try ensureWorkspaceFilesLocked(createdAt: date)
            state.streamingBackendStatus = status
            state.updatedAt = date
            if let note {
                state.note = note
                try appendText("\n\(note)\n", to: liveTranscriptURL)
            }
            try writeState()
            try writePreview()
        }
    }

    private func withSessionLock<T>(_ body: () throws -> T) rethrows -> T {
        sessionLock.lock()
        defer { sessionLock.unlock() }
        return try body()
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

    private func writePreview() throws {
        let transcript = (try? String(contentsOf: liveTranscriptURL, encoding: .utf8))
            ?? idleTranscriptText()
        try writeTextIfChanged(previewHTML(transcript: transcript), to: previewURL)
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
        Streaming backend: local Parakeet streaming ASR sidecar.

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
        - `preview.html` is a live transcript preview snapshot. The local browser URL updates without full-page refreshes.
        - `\(Self.previewServerURL.absoluteString)` is the Codex in-app browser preview while Transcripted is running.

        Important:
        - The live transcript is provisional.
        - Lines marked `[partial]` are streaming ASR hypotheses and may change.
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
        - Treat `[partial]` lines as live hypotheses.
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
        - Browser preview: \(Self.previewServerURL.absoluteString)

        How to work:
        1. Read `state.json`.
        2. While status is `recording`, read `live_transcript.md` whenever I ask about the meeting.
        3. Treat live text as provisional and source-labeled.
        4. Treat `[partial]` lines as live hypotheses that may change.
        5. Once `finalTranscriptPath` is present, read that final Transcripted Markdown and prefer it for speaker names, diarization, and final notes.
        6. If I ask for a live view in Codex, open \(Self.previewServerURL.absoluteString). If Transcripted is closed, fall back to `preview.html` from this folder.

        Do not alter the normal Transcripted meeting output.
        """
    }

    private func previewHTML(transcript: String) -> String {
        let status = "\(state.status.rawValue) - \(state.streamingBackendStatus)"
        let escapedStatus = Self.htmlEscaped(status)
        let escapedNote = Self.htmlEscaped(state.note)
        let escapedUpdatedAt = Self.htmlEscaped(Self.isoString(state.updatedAt))
        let escapedTranscript = Self.htmlEscaped(transcript)
        return """
        <!doctype html>
        <html lang="en">
        <head>
          <meta charset="utf-8">
          <meta name="viewport" content="width=device-width, initial-scale=1">
          <title>Transcripted Live Meeting</title>
          <style>
            :root {
              color-scheme: light dark;
              font-family: -apple-system, BlinkMacSystemFont, "Segoe UI", sans-serif;
              background: Canvas;
              color: CanvasText;
            }
            body { margin: 0; padding: 18px; }
            main { max-width: 980px; margin: 0 auto; }
            header {
              display: grid;
              grid-template-columns: 1fr auto;
              gap: 12px;
              align-items: start;
              border-bottom: 1px solid color-mix(in srgb, CanvasText 16%, transparent);
              padding-bottom: 12px;
              margin-bottom: 14px;
            }
            h1 { font-size: 18px; margin: 0 0 4px; }
            .meta { font-size: 12px; color: color-mix(in srgb, CanvasText 68%, transparent); line-height: 1.45; }
            .status {
              font-size: 12px;
              padding: 5px 8px;
              border: 1px solid color-mix(in srgb, CanvasText 16%, transparent);
              border-radius: 8px;
              white-space: nowrap;
            }
            pre {
              white-space: pre-wrap;
              word-wrap: break-word;
              font: 13px/1.55 ui-monospace, SFMono-Regular, Menlo, monospace;
              margin: 0;
              min-height: 72vh;
            }
          </style>
        </head>
        <body>
          <main>
            <header>
              <div>
                <h1>Transcripted Live Meeting</h1>
                <div class="meta">Updated <span id="updated-at">\(escapedUpdatedAt)</span><br><span id="note">\(escapedNote)</span></div>
              </div>
              <div class="status" id="status">\(escapedStatus)</div>
            </header>
            <pre id="transcript">\(escapedTranscript)</pre>
          </main>
          <script>
            const stateURL = window.location.protocol === "file:" ? "state.json" : "/state.json";
            const transcriptURL = window.location.protocol === "file:" ? "live_transcript.md" : "/live_transcript.md";
            const statusElement = document.getElementById("status");
            const updatedAtElement = document.getElementById("updated-at");
            const noteElement = document.getElementById("note");
            const transcriptElement = document.getElementById("transcript");
            let lastTranscript = transcriptElement.textContent;

            function isNearBottom() {
              return window.innerHeight + window.scrollY >= document.body.scrollHeight - 120;
            }

            async function refreshPreview() {
              const shouldFollow = isNearBottom();
              try {
                const [stateResponse, transcriptResponse] = await Promise.all([
                  fetch(`${stateURL}?t=${Date.now()}`, { cache: "no-store" }),
                  fetch(`${transcriptURL}?t=${Date.now()}`, { cache: "no-store" })
                ]);

                if (stateResponse.ok) {
                  const state = await stateResponse.json();
                  statusElement.textContent = `${state.status} - ${state.streamingBackendStatus}`;
                  updatedAtElement.textContent = state.updatedAt || "";
                  noteElement.textContent = state.note || "";
                }

                if (transcriptResponse.ok) {
                  const transcript = await transcriptResponse.text();
                  if (transcript !== lastTranscript) {
                    transcriptElement.textContent = transcript;
                    lastTranscript = transcript;
                    if (shouldFollow) {
                      window.scrollTo(0, document.body.scrollHeight);
                    }
                  }
                }
              } catch (_) {
                // Keep the current snapshot if Transcripted is restarting.
              }
            }

            window.addEventListener("load", () => {
              window.scrollTo(0, document.body.scrollHeight);
              refreshPreview();
              if (window.location.protocol !== "file:") {
                window.setInterval(refreshPreview, 1000);
              }
            });

            document.addEventListener("visibilitychange", () => {
              if (!document.hidden) {
                refreshPreview();
              }
            });
          </script>
        </body>
        </html>
        """
    }

    private static func htmlEscaped(_ text: String) -> String {
        text
            .replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;")
            .replacingOccurrences(of: "\"", with: "&quot;")
            .replacingOccurrences(of: "'", with: "&#39;")
    }

    private static func isoString(_ date: Date) -> String {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter.string(from: date)
    }
}
