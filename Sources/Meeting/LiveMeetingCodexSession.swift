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
        let escapedDisplayStatus = Self.htmlEscaped(state.status.rawValue)
        let escapedNote = Self.htmlEscaped(state.note)
        let escapedUpdatedAt = Self.htmlEscaped(Self.isoString(state.updatedAt))
        let escapedTitle = Self.htmlEscaped(state.title ?? "Live Meeting")
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
              --bg: #0f1115;
              --panel: #171a20;
              --panel-2: #1f232b;
              --text: #f3f5f7;
              --muted: #98a1ad;
              --line: rgba(255, 255, 255, 0.11);
              --mic: #65d6ad;
              --system: #8ab4ff;
              --partial: #ffd166;
              --ready: #75e39c;
              font-family: ui-sans-serif, -apple-system, BlinkMacSystemFont, "Segoe UI", sans-serif;
              background: #0f1115;
              color: var(--text);
            }
            * { box-sizing: border-box; }
            body {
              min-height: 100vh;
              margin: 0;
              padding: 10px 12px 18px;
            }
            main {
              max-width: 980px;
              margin: 0 auto;
            }
            header {
              position: sticky;
              top: 0;
              z-index: 2;
              display: grid;
              grid-template-columns: 1fr;
              gap: 8px;
              padding: 8px 2px 10px;
              margin-bottom: 4px;
              border-bottom: 1px solid var(--line);
              background: color-mix(in srgb, var(--bg) 88%, transparent);
              backdrop-filter: blur(18px);
            }
            .header-main {
              display: grid;
              grid-template-columns: 1fr auto;
              gap: 10px;
              align-items: start;
            }
            h1 {
              margin: 0;
              font-size: 15px;
              font-weight: 760;
              letter-spacing: 0;
            }
            .subtitle {
              margin-top: 2px;
              color: var(--muted);
              font-size: 11px;
              line-height: 1.35;
            }
            .status {
              justify-self: end;
              font-size: 11px;
              padding: 4px 8px;
              border: 1px solid rgba(117, 227, 156, 0.36);
              border-radius: 999px;
              background: rgba(117, 227, 156, 0.1);
              color: var(--ready);
              white-space: nowrap;
            }
            .meta-row {
              display: flex;
              flex-wrap: wrap;
              gap: 8px 14px;
            }
            .meta-card {
              min-width: 0;
              padding: 0;
            }
            .meta-label {
              display: block;
              margin-bottom: 1px;
              color: var(--muted);
              font-size: 9px;
              font-weight: 700;
              letter-spacing: 0;
              text-transform: uppercase;
            }
            .meta-value {
              overflow: hidden;
              color: var(--text);
              font-size: 11px;
              line-height: 1.35;
              text-overflow: ellipsis;
              white-space: nowrap;
            }
            .meta-note {
              display: block;
              max-width: min(100%, 640px);
              overflow: hidden;
              overflow-wrap: anywhere;
              text-overflow: ellipsis;
              white-space: nowrap;
            }
            .toolbar {
              display: flex;
              flex-wrap: wrap;
              gap: 6px;
              align-items: center;
            }
            .filter-button {
              border: 1px solid var(--line);
              border-radius: 999px;
              padding: 4px 8px;
              background: transparent;
              color: var(--muted);
              font: inherit;
              font-size: 11px;
              cursor: pointer;
            }
            .filter-button[aria-pressed="true"] {
              border-color: rgba(255, 255, 255, 0.28);
              background: rgba(255, 255, 255, 0.08);
              color: var(--text);
            }
            .stream {
              display: grid;
              gap: 0;
              align-content: start;
              min-height: 0;
              padding-bottom: 18px;
            }
            .utterance,
            .notice,
            .empty-state {
              border-bottom: 1px solid var(--line);
            }
            .utterance {
              display: grid;
              grid-template-columns: 58px minmax(0, 1fr);
              gap: 8px;
              padding: 8px 2px;
              align-items: start;
            }
            .time {
              color: var(--muted);
              font: 11px/1.45 ui-monospace, SFMono-Regular, Menlo, monospace;
            }
            .line-body {
              min-width: 0;
            }
            .line-top {
              display: flex;
              flex-wrap: wrap;
              gap: 6px;
              align-items: center;
            }
            .source,
            .partial {
              border-radius: 999px;
              padding: 2px 6px;
              font-size: 10px;
              font-weight: 760;
              letter-spacing: 0;
            }
            .source-microphone .source {
              background: rgba(101, 214, 173, 0.14);
              color: var(--mic);
            }
            .source-system .source {
              background: rgba(138, 180, 255, 0.15);
              color: var(--system);
            }
            .partial {
              background: rgba(255, 209, 102, 0.14);
              color: var(--partial);
            }
            .text {
              margin: 0;
              color: var(--text);
              font-size: 13px;
              line-height: 1.42;
              overflow-wrap: anywhere;
            }
            .notice {
              padding: 8px 2px;
              color: var(--muted);
              font-size: 12px;
              line-height: 1.4;
            }
            .notice strong {
              color: var(--text);
            }
            .empty-state {
              padding: 20px 2px;
              color: var(--muted);
              text-align: center;
            }
            .hidden {
              display: none;
            }
            @media (prefers-color-scheme: light) {
              :root {
                --bg: #f4f0e8;
                --panel: #fffaf0;
                --panel-2: #f3eadc;
                --text: #1f2328;
                --muted: #69707a;
                --line: rgba(31, 35, 40, 0.12);
                --mic: #087c5c;
                --system: #2458bd;
                --partial: #936200;
                --ready: #177245;
                background: #fbf7ee;
              }
            }
            @media (max-width: 680px) {
              body { padding: 10px; }
              .header-main,
              .meta-row {
                grid-template-columns: 1fr;
              }
              .status {
                justify-self: start;
              }
              .utterance {
                grid-template-columns: 50px minmax(0, 1fr);
                gap: 6px 8px;
              }
            }
          </style>
        </head>
        <body>
          <main>
            <header>
              <div class="header-main">
                <div>
                  <h1 id="meeting-title">\(escapedTitle)</h1>
                  <div class="subtitle">Transcripted live sidecar for Codex</div>
                </div>
                <div class="status" id="status" title="\(escapedStatus)">\(escapedDisplayStatus)</div>
              </div>
              <div class="meta-row">
                <div class="meta-card">
                  <span class="meta-label">Updated</span>
                  <span class="meta-value" id="updated-at">\(escapedUpdatedAt)</span>
                </div>
                <div class="meta-card">
                  <span class="meta-label">Source</span>
                  <span class="meta-value" id="source-summary">Mic + system</span>
                </div>
                <div class="meta-card">
                  <span class="meta-label">State</span>
                  <span class="meta-value meta-note" id="note">\(escapedNote)</span>
                </div>
              </div>
              <div class="toolbar" aria-label="Transcript filters">
                <button class="filter-button" type="button" data-filter="all" aria-pressed="true">All</button>
                <button class="filter-button" type="button" data-filter="microphone" aria-pressed="false">Mic</button>
                <button class="filter-button" type="button" data-filter="system" aria-pressed="false">System</button>
              </div>
            </header>
            <section class="stream" id="transcript" aria-live="polite"></section>
            <textarea class="hidden" id="initial-transcript" readonly>\(escapedTranscript)</textarea>
          </main>
          <script>
            const stateURL = window.location.protocol === "file:" ? "state.json" : "/state.json";
            const transcriptURL = window.location.protocol === "file:" ? "live_transcript.md" : "/live_transcript.md";
            const statusElement = document.getElementById("status");
            const titleElement = document.getElementById("meeting-title");
            const updatedAtElement = document.getElementById("updated-at");
            const noteElement = document.getElementById("note");
            const sourceSummaryElement = document.getElementById("source-summary");
            const transcriptElement = document.getElementById("transcript");
            const initialTranscriptElement = document.getElementById("initial-transcript");
            const filterButtons = Array.from(document.querySelectorAll("[data-filter]"));
            let lastTranscript = initialTranscriptElement.value;
            let activeFilter = "all";

            function isNearBottom() {
              return window.innerHeight + window.scrollY >= document.body.scrollHeight - 120;
            }

            function escapeHTML(value) {
              return value
                .replace(/&/g, "&amp;")
                .replace(/</g, "&lt;")
                .replace(/>/g, "&gt;")
                .replace(/"/g, "&quot;")
                .replace(/'/g, "&#39;");
            }

            function displaySource(source) {
              return source === "system" ? "System" : "Mic";
            }

            function parseTranscript(markdown) {
              const lines = markdown.split(/\\r?\\n/);
              const entries = [];
              let inTranscript = false;
              for (const line of lines) {
                if (line.trim() === "## Live Transcript") {
                  inTranscript = true;
                  continue;
                }

                if (!inTranscript) {
                  continue;
                }

                const utterance = line.match(/^\\*\\*(\\d{2}:\\d{2}(?::\\d{2})?)\\*\\* \\[(Microphone|System)\\](?: \\[(partial)\\])?\\s*(.*)$/);
                if (utterance) {
                  entries.push({
                    kind: "utterance",
                    time: utterance[1],
                    source: utterance[2] === "System" ? "system" : "microphone",
                    partial: Boolean(utterance[3]),
                    text: utterance[4]
                  });
                  continue;
                }

                const trimmed = line.trim();
                if (trimmed) {
                  const previous = entries[entries.length - 1];
                  if (previous && previous.kind === "notice") {
                    previous.text = `${previous.text}\\n${trimmed}`;
                  } else {
                    entries.push({ kind: "notice", text: trimmed });
                  }
                }
              }
              return entries;
            }

            function renderTranscript(markdown) {
              const entries = parseTranscript(markdown);
              const visibleEntries = entries.filter((entry) => {
                return entry.kind !== "utterance" || activeFilter === "all" || entry.source === activeFilter;
              });
              const hasMic = entries.some((entry) => entry.kind === "utterance" && entry.source === "microphone");
              const hasSystem = entries.some((entry) => entry.kind === "utterance" && entry.source === "system");
              if (hasMic && hasSystem) {
                sourceSummaryElement.textContent = "Mic + system";
              } else if (hasMic) {
                sourceSummaryElement.textContent = "Mic only";
              } else if (hasSystem) {
                sourceSummaryElement.textContent = "System only";
              } else {
                sourceSummaryElement.textContent = "Waiting";
              }

              if (visibleEntries.length === 0) {
                transcriptElement.innerHTML = '<div class="empty-state">Waiting for live transcript text.</div>';
                return;
              }

              transcriptElement.innerHTML = visibleEntries.map((entry) => {
                if (entry.kind === "notice") {
                  return `<div class="notice">${escapeHTML(entry.text).replace(/\\n/g, "<br>")}</div>`;
                }
                const partial = entry.partial ? '<span class="partial">Partial</span>' : "";
                return `
                  <article class="utterance source-${entry.source}" data-source="${entry.source}">
                    <div class="time">${escapeHTML(entry.time)}</div>
                    <div class="line-body">
                      <div class="line-top">
                        <span class="source">${displaySource(entry.source)}</span>
                        ${partial}
                      </div>
                      <p class="text">${escapeHTML(entry.text)}</p>
                    </div>
                  </article>
                `;
              }).join("");
            }

            filterButtons.forEach((button) => {
              button.addEventListener("click", () => {
                activeFilter = button.dataset.filter || "all";
                filterButtons.forEach((candidate) => {
                  candidate.setAttribute("aria-pressed", String(candidate === button));
                });
                renderTranscript(lastTranscript);
              });
            });

            async function refreshPreview() {
              const shouldFollow = isNearBottom();
              try {
                const [stateResponse, transcriptResponse] = await Promise.all([
                  fetch(`${stateURL}?t=${Date.now()}`, { cache: "no-store" }),
                  fetch(`${transcriptURL}?t=${Date.now()}`, { cache: "no-store" })
                ]);

                if (stateResponse.ok) {
                  const state = await stateResponse.json();
                  statusElement.textContent = state.status || "";
                  statusElement.title = `${state.status || ""} - ${state.streamingBackendStatus || ""}`;
                  titleElement.textContent = state.title || "Live Meeting";
                  updatedAtElement.textContent = state.updatedAt || "";
                  noteElement.textContent = state.note || "";
                }

                if (transcriptResponse.ok) {
                  const transcript = await transcriptResponse.text();
                  if (transcript !== lastTranscript) {
                    lastTranscript = transcript;
                    renderTranscript(transcript);
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
              renderTranscript(lastTranscript);
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
