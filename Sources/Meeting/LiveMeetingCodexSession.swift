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
    case disabled
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
    static let workspaceFolderName = "AgentLiveMeeting"
    static let liveTranscriptFilename = "live_transcript.md"
    static let stateFilename = "state.json"
    static let setupFilename = "agent-live-meeting.md"
    static let handoffFilename = "agent-handoff.md"
    static let watcherStateFilename = "agent-watcher-state.json"
    static let previewFilename = "preview.html"
    static let previewAuthTokenFilename = ".preview-token"
    static let previewServerPort: UInt16 = 47834
    static let previewServerPath = "/live-preview"

    static var previewServerURL: URL {
        URL(string: "http://127.0.0.1:\(previewServerPort)\(previewServerPath)")!
    }

    static func authenticatedPreviewServerURL(token: String) -> URL {
        var components = URLComponents(url: previewServerURL, resolvingAgainstBaseURL: false)
        components?.queryItems = [URLQueryItem(name: "token", value: token)]
        return components?.url ?? previewServerURL
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
    // In-memory mirror of the last known text per workspace file. Without it,
    // every accepted transcript entry re-reads the growing transcript and
    // preview from disk just to compare, so total I/O grows quadratically
    // with meeting length. Guarded by sessionLock like the rest of the state.
    private var knownFileText: [String: String] = [:]
    private var lastPreviewWriteAt = Date.distantPast
    // Rendering preview.html is O(transcript length), so per-entry appends
    // only refresh it every few seconds; lifecycle transitions force a fresh
    // snapshot. The served page polls live_transcript.md directly, so the
    // live view stays current regardless.
    private static let previewRewriteInterval: TimeInterval = 2.0

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
            note: "Live meeting sidecar is ready. Final Transcripted meeting Markdown still saves normally after recording stops."
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

    var handoffURL: URL {
        workspaceRoot.appendingPathComponent(Self.handoffFilename, isDirectory: false)
    }

    var watcherStateURL: URL {
        workspaceRoot.appendingPathComponent(Self.watcherStateFilename, isDirectory: false)
    }

    var previewURL: URL {
        workspaceRoot.appendingPathComponent(Self.previewFilename, isDirectory: false)
    }

    var previewAuthTokenURL: URL {
        workspaceRoot.appendingPathComponent(Self.previewAuthTokenFilename, isDirectory: false)
    }

    func previewServerBrowserURL() -> URL {
        guard let token = try? ensurePreviewAuthToken() else {
            return Self.previewServerURL
        }
        return Self.authenticatedPreviewServerURL(token: token)
    }

    func ensureWorkspaceFiles(createdAt: Date = Date()) throws {
        try withSessionLock {
            try ensureWorkspaceFilesLocked(createdAt: createdAt)
        }
    }

    @discardableResult
    func ensurePreviewAuthToken() throws -> String {
        try withSessionLock {
            try ensurePreviewAuthTokenLocked()
        }
    }

    private func ensureWorkspaceFilesLocked(createdAt: Date = Date(), forcePreviewRewrite: Bool = true) throws {
        try fileManager.createPrivateDirectory(at: workspaceRoot)
        _ = try ensurePreviewAuthTokenLocked()
        try writeTextIfChanged(readmeText(), to: workspaceRoot.appendingPathComponent("README.md", isDirectory: false))
        try writeTextIfChanged(agentsText(), to: workspaceRoot.appendingPathComponent("AGENTS.md", isDirectory: false))
        try writeTextIfChanged(setupText(), to: setupURL)

        loadStoredStateIfAvailable()

        if !fileManager.fileExists(atPath: stateURL.path) {
            state.updatedAt = createdAt
            try writeState()
        }

        if !fileManager.fileExists(atPath: liveTranscriptURL.path) {
            try writeTextIfChanged(idleTranscriptText(), to: liveTranscriptURL)
        }
        if !fileManager.fileExists(atPath: watcherStateURL.path) {
            try writeTextIfChanged(initialWatcherStateText(), to: watcherStateURL)
        }
        try rewriteLiveTranscriptStatus(state.status.rawValue)

        try syncHandoffWithState(fallbackDate: createdAt)
        try writePreview(force: forcePreviewRewrite)
    }

    private func ensurePreviewAuthTokenLocked() throws -> String {
        try fileManager.createPrivateDirectory(at: workspaceRoot)
        if let existingText = try? String(contentsOf: previewAuthTokenURL, encoding: .utf8) {
            let existing = existingText.trimmingCharacters(in: .whitespacesAndNewlines)
            if existing.count >= 32 {
                return existing
            }
        }

        let token = Self.generatePreviewAuthToken()
        try writeTextIfChanged("\(token)\n", to: previewAuthTokenURL)
        return token
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
                note: "This is a provisional live sidecar for agents. The final Transcripted Markdown is written by the normal meeting pipeline."
            )

            try writeTextIfChanged(liveTranscriptHeader(title: title, startedAt: startedAt), to: liveTranscriptURL)
            try writeTextIfChanged(recordingHandoffText(title: title, startedAt: startedAt), to: handoffURL)
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

            try ensureWorkspaceFilesLocked(forcePreviewRewrite: false)
            let marker = entry.isFinal ? "" : " [partial]"
            let line = "**\(Self.timestamp(entry.timestampSeconds))** \(entry.source.markdownTag)\(marker) \(text)\n"
            try appendText(line, to: liveTranscriptURL)
            state.updatedAt = entry.createdAt
            try writeState()
            try writePreview(force: false)
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
                try rewriteLiveTranscriptStatus(status.rawValue)
                try appendText("\nRecording stopped. Waiting for final Transcripted transcript.\n", to: liveTranscriptURL)
                try writeTextIfChanged(waitingHandoffText(title: state.title, stoppedAt: date), to: handoffURL)
            case .cancelled:
                state.streamingBackendStatus = "cancelled"
                state.note = "Recording cancelled. No final meeting transcript will be saved for this capture."
                try rewriteLiveTranscriptStatus(status.rawValue)
                try appendText("\nRecording cancelled. No final transcript will be saved for this capture.\n", to: liveTranscriptURL)
                try writeTextIfChanged(cancelledHandoffText(title: state.title, endedAt: date), to: handoffURL)
            case .failed:
                state.streamingBackendStatus = "failed"
                state.note = "Recording ended with an error. Check Transcripted for retry details."
                try rewriteLiveTranscriptStatus(status.rawValue)
                try appendText("\nRecording ended with an error. Check Transcripted for retry details.\n", to: liveTranscriptURL)
                try writeTextIfChanged(failedHandoffText(title: state.title, endedAt: date), to: handoffURL)
            case .disabled:
                state.streamingBackendStatus = "disabled"
                state.note = "Live sidecar was disabled. Transcripted will keep saving the normal final meeting Markdown."
                try rewriteLiveTranscriptStatus(status.rawValue)
                try appendText("\nLive sidecar disabled. Transcripted will still save the normal final transcript.\n", to: liveTranscriptURL)
                try writeTextIfChanged(disabledHandoffText(title: state.title, endedAt: date), to: handoffURL)
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
            try rewriteLiveTranscriptStatus(state.status.rawValue)

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
            try writeTextIfChanged(finalHandoffText(url: url, title: state.title, savedAt: date), to: handoffURL)
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

    func markSidecarAppendFailed(note: String, at date: Date = Date()) throws {
        try withSessionLock {
            try ensureWorkspaceFilesLocked(createdAt: date, forcePreviewRewrite: false)
            state.status = .failed
            state.streamingBackendStatus = "sidecar_append_failed"
            state.updatedAt = date
            state.note = note

            // Persist state first. The live transcript itself may be locked,
            // missing, or on a full volume, so failure to append the note must
            // not hide the failed sidecar status from agents or the preview.
            try writeState()
            try? rewriteLiveTranscriptStatus(state.status.rawValue)
            try? appendText("\n\(note)\n", to: liveTranscriptURL)
            try? writeTextIfChanged(failedHandoffText(title: state.title, endedAt: date), to: handoffURL)
            try? writePreview()
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

    private func loadStoredStateIfAvailable() {
        guard fileManager.fileExists(atPath: stateURL.path),
              let data = try? Data(contentsOf: stateURL) else {
            return
        }

        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        if let storedState = try? decoder.decode(LiveMeetingCodexState.self, from: data) {
            state = storedState
        }
    }

    private func syncHandoffWithState(fallbackDate: Date) throws {
        let date = state.updatedAt.timeIntervalSince1970 > 0 ? state.updatedAt : fallbackDate
        switch state.status {
        case .idle:
            try writeTextIfChanged(idleHandoffText(), to: handoffURL)
        case .recording:
            try writeTextIfChanged(
                recordingHandoffText(title: state.title, startedAt: state.startedAt ?? date),
                to: handoffURL
            )
        case .stopped:
            try writeTextIfChanged(waitingHandoffText(title: state.title, stoppedAt: date), to: handoffURL)
        case .transcriptSaved:
            if let finalTranscriptPath = state.finalTranscriptPath, !finalTranscriptPath.isEmpty {
                try writeTextIfChanged(
                    finalHandoffText(url: URL(fileURLWithPath: finalTranscriptPath), title: state.title, savedAt: date),
                    to: handoffURL
                )
            } else {
                try writeTextIfChanged(waitingHandoffText(title: state.title, stoppedAt: date), to: handoffURL)
            }
        case .cancelled:
            try writeTextIfChanged(cancelledHandoffText(title: state.title, endedAt: date), to: handoffURL)
        case .failed:
            try writeTextIfChanged(failedHandoffText(title: state.title, endedAt: date), to: handoffURL)
        case .disabled:
            try writeTextIfChanged(disabledHandoffText(title: state.title, endedAt: date), to: handoffURL)
        }
    }

    private func textCacheKey(for url: URL) -> String {
        url.standardizedFileURL.path
    }

    // Returns the last text this session wrote to `url`, falling back to one
    // disk read per file per session so identical rewrites are still skipped
    // across app restarts.
    private func knownText(at url: URL) -> String? {
        let key = textCacheKey(for: url)
        if let cached = knownFileText[key] {
            return cached
        }
        guard let existing = try? String(contentsOf: url, encoding: .utf8) else {
            return nil
        }
        knownFileText[key] = existing
        return existing
    }

    private func writeTextIfChanged(_ text: String, to url: URL) throws {
        if knownText(at: url) == text, fileManager.fileExists(atPath: url.path) {
            fileManager.restrictFileToOwnerOnly(at: url)
            return
        }

        try text.write(to: url, atomically: true, encoding: .utf8)
        fileManager.restrictFileToOwnerOnly(at: url)
        knownFileText[textCacheKey(for: url)] = text
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

        let key = textCacheKey(for: url)
        if let known = knownFileText[key] {
            knownFileText[key] = known + text
        } else {
            knownFileText[key] = try? String(contentsOf: url, encoding: .utf8)
        }
    }

    private func rewriteLiveTranscriptStatus(_ status: String) throws {
        let existing = knownText(at: liveTranscriptURL) ?? idleTranscriptText()
        var lines = existing
            .split(separator: "\n", omittingEmptySubsequences: false)
            .map(String.init)

        if let statusIndex = lines.firstIndex(where: { $0.hasPrefix("Status: ") }) {
            lines[statusIndex] = "Status: \(status)"
        } else {
            lines.insert("Status: \(status)", at: min(2, lines.count))
        }

        try writeTextIfChanged(lines.joined(separator: "\n"), to: liveTranscriptURL)
    }

    private func writePreview(force: Bool = true) throws {
        let now = Date()
        if !force, now.timeIntervalSince(lastPreviewWriteAt) < Self.previewRewriteInterval {
            return
        }

        let transcript = knownText(at: liveTranscriptURL) ?? idleTranscriptText()
        try writeTextIfChanged(previewHTML(transcript: transcript), to: previewURL)
        lastPreviewWriteAt = now
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

        Enable Live Meeting Sidecar from Transcripted Settings > Agent, then start a meeting.
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

        This file is a provisional live sidecar for agents.
        Transcripted still saves the normal final meeting Markdown after recording stops.
        Streaming backend: local Parakeet streaming ASR sidecar.

        ## Live Transcript

        """
    }

    private func idleHandoffText() -> String {
        """
        # Transcripted Agent Handoff

        Status: idle

        No finished meeting is ready yet.
        Agents should use `live_transcript.md` only while a meeting is recording.

        """
    }

    private func recordingHandoffText(title: String?, startedAt: Date) -> String {
        let titleLine = handoffTitleLine(title)
        return """
        # Transcripted Agent Handoff

        Status: recording
        \(titleLine)Started: \(Self.isoString(startedAt))
        Live transcript path: \(liveTranscriptURL.path)
        State path: \(stateURL.path)

        Agents should treat the live transcript as provisional until this file changes to `Status: ready`.

        """
    }

    private func waitingHandoffText(title: String?, stoppedAt: Date) -> String {
        let titleLine = handoffTitleLine(title)
        return """
        # Transcripted Agent Handoff

        Status: waiting_for_final_transcript
        \(titleLine)Stopped: \(Self.isoString(stoppedAt))
        Live transcript path: \(liveTranscriptURL.path)
        State path: \(stateURL.path)

        Recording has stopped. Wait for Transcripted to write the final Markdown before using durable notes.

        """
    }

    private func cancelledHandoffText(title: String?, endedAt: Date) -> String {
        let titleLine = handoffTitleLine(title)
        return """
        # Transcripted Agent Handoff

        Status: cancelled
        \(titleLine)Ended: \(Self.isoString(endedAt))

        No final transcript will be handed off for this recording.

        """
    }

    private func failedHandoffText(title: String?, endedAt: Date) -> String {
        let titleLine = handoffTitleLine(title)
        return """
        # Transcripted Agent Handoff

        Status: failed
        \(titleLine)Ended: \(Self.isoString(endedAt))

        Transcripted could not finish this recording. Check Transcripted for retry details before summarizing.

        """
    }

    private func disabledHandoffText(title: String?, endedAt: Date) -> String {
        let titleLine = handoffTitleLine(title)
        return """
        # Transcripted Agent Handoff

        Status: disabled
        \(titleLine)Ended: \(Self.isoString(endedAt))

        The user turned off the live sidecar. Transcripted will still save the normal final meeting Markdown.

        """
    }

    private func finalHandoffText(url: URL, title: String?, savedAt: Date) -> String {
        let titleLine = handoffTitleLine(title)
        return """
        # Transcripted Agent Handoff

        Status: ready
        \(titleLine)Saved: \(Self.isoString(savedAt))
        Final transcript path: \(url.standardizedFileURL.path)
        Live transcript path: \(liveTranscriptURL.path)
        State path: \(stateURL.path)

        Agent automatic behavior:
        - Treat this file as the post-recording handoff marker.
        - Read the final transcript path above as soon as a watcher sees this file change.
        - Check `\(Self.watcherStateFilename)` before waking the user; stay quiet if `lastHandledFinalTranscriptPath` already matches this final transcript.
        - After handling this final transcript, update `\(Self.watcherStateFilename)` with the final path and current time.
        - Use the final Markdown as canonical. Do not summarize from `live_transcript.md` once this is ready.
        - Produce a concise meeting brief with summary, decisions, action items, and next steps unless the user asks for something narrower.

        """
    }

    private func handoffTitleLine(_ title: String?) -> String {
        guard let title, !title.isEmpty else { return "" }
        return "Title: \(title)\n"
    }

    private func readmeText() -> String {
        let browserPreviewURL = previewServerBrowserURL().absoluteString
        return """
        # Transcripted Live Meeting Sidecar

        This folder is a live sidecar workspace for an active Transcripted meeting.

        Files:
        - `live_transcript.md` is the provisional live transcript stream.
        - `state.json` says whether recording is active and where the final Transcripted Markdown lands.
        - `agent-handoff.md` is the automatic handoff marker for the final transcript.
        - `agent-watcher-state.json` is agent-owned memory for the last final transcript already handled.
        - `agent-live-meeting.md` is the setup prompt for Codex or Claude Cowork.
        - `preview.html` is a live transcript preview snapshot. The local browser URL updates without full-page refreshes.
        - `\(browserPreviewURL)` is the live browser preview while Transcripted is running.

        Important:
        - The live transcript is provisional.
        - Lines marked `[partial]` are streaming ASR hypotheses and may change.
        - The normal Transcripted meeting Markdown still saves in the capture library after stop.
        - Once `agent-handoff.md` says `Status: ready` or `state.json` has `finalTranscriptPath`, prefer that final Markdown for names, diarization, and durable notes.
        - After an agent handles a ready final transcript, update `agent-watcher-state.json` so repeat watchers stay quiet.

        Workspace:
        \(workspaceRoot.path)
        """
    }

    private func agentsText() -> String {
        """
        # Transcripted Live Meeting Sidecar

        You are in a Transcripted live-meeting sidecar workspace for Codex or Claude Cowork.

        Start with:
        - `state.json`
        - `live_transcript.md`
        - `agent-handoff.md`
        - `agent-watcher-state.json`
        - `agent-live-meeting.md`

        Rules:
        - Treat `live_transcript.md` as provisional while `status` is `recording`.
        - Treat `[partial]` lines as live hypotheses.
        - Keep source labels like `[Microphone]` and `[System]` in mind.
        - If mic and system audio appear duplicated, say that plainly when it matters.
        - If `agent-handoff.md` says `Status: ready` or `state.json` has `finalTranscriptPath`, read that final Markdown and prefer it for participant names, diarization, quotes, decisions, and durable notes.
        - Before handling a ready final transcript, check `agent-watcher-state.json`. If `lastHandledFinalTranscriptPath` matches the ready final path, stay quiet unless the user asks.
        - After handling a ready final transcript, update `lastHandledFinalTranscriptPath` and `lastHandledAt` in `agent-watcher-state.json`.
        - Do not change Transcripted's meeting files unless the user asks.
        - Keep live answers short. Say when the live stream is too sparse to answer.
        - Keep the workflow local. Do not ask the user to paste the transcript elsewhere.
        """
    }

    private func setupText() -> String {
        let browserPreviewURL = previewServerBrowserURL().absoluteString
        return """
        # Transcripted Live Meeting Agent Setup

        Use this agent chat as my live Transcripted meeting room.

        Local paths:
        - Workspace: \(workspaceRoot.path)
        - Live transcript: \(liveTranscriptURL.path)
        - State: \(stateURL.path)
        - Automatic handoff: \(handoffURL.path)
        - Watcher state: \(watcherStateURL.path)
        - Preview: \(previewURL.path)
        - Browser preview: \(browserPreviewURL)

        How to work:
        1. Read `state.json`.
        2. While status is `recording`, read `live_transcript.md` whenever I ask about the meeting.
        3. Treat live text as provisional and source-labeled.
        4. Treat `[partial]` lines as live hypotheses that may change.
        5. Once `agent-handoff.md` says `Status: ready` or `finalTranscriptPath` is present, read that final Transcripted Markdown and prefer it for speaker names, diarization, and final notes.
        6. Before posting a post-meeting brief or waking me about the ready transcript, check `agent-watcher-state.json`. If `lastHandledFinalTranscriptPath` already matches the ready final path, stay quiet unless I ask.
        7. After you handle a ready final transcript, update `agent-watcher-state.json` with that path and the current time.
        8. For Codex, open \(browserPreviewURL) for the live view while Transcripted is running. For Claude Cowork, use the same workspace files or `preview.html` if folder access is granted.
        9. Keep this local. Do not ask me to copy the transcript into another tool.

        Do not alter the normal Transcripted meeting output.
        """
    }

    private func initialWatcherStateText() -> String {
        """
        {
          "version": 1,
          "lastHandledFinalTranscriptPath": null,
          "lastHandledAt": null,
          "note": "An agent may update this file after handling a final transcript so repeat watchers stay quiet."
        }
        """
    }

    private func previewHTML(transcript: String) -> String {
        let status = "\(state.status.rawValue) - \(state.streamingBackendStatus)"
        let escapedStatus = Self.htmlEscaped(status)
        let statusLine: String
        switch state.status {
        case .recording:
            statusLine = "Recording locally"
        case .transcriptSaved:
            statusLine = "Transcript saved"
        case .stopped:
            statusLine = "Waiting for transcript"
        case .cancelled:
            statusLine = "Recording cancelled."
        case .failed:
            statusLine = "Needs attention"
        case .disabled:
            statusLine = "Live sidecar disabled"
        case .idle:
            statusLine = "Not recording"
        }
        let escapedDisplayStatus = Self.htmlEscaped(statusLine)
        let escapedTitle = Self.htmlEscaped(state.title ?? "Live Meeting")
        let escapedTranscript = Self.htmlEscaped(transcript)
        let previewAuthToken = (try? ensurePreviewAuthToken()) ?? ""
        let escapedPreviewAuthToken = Self.javaScriptEscaped(previewAuthToken)
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
            .handoff {
              padding: 0 8px 12px;
              border-bottom: 1px solid var(--line);
            }
            .handoff[hidden] {
              display: none;
            }
            .handoff-title {
              margin: 0;
              color: var(--muted);
              font-size: 13px;
              line-height: 1.35;
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
            .live-note {
              display: grid;
              min-height: calc(100vh - 28px);
              grid-template-rows: auto auto 1fr auto;
              gap: 14px;
            }
            .note-header {
              position: static;
              display: grid;
              gap: 10px;
              padding: 26px 8px 0;
              margin: 0;
              border: 0;
              background: transparent;
              backdrop-filter: none;
            }
            .note-topline {
              display: flex;
              align-items: center;
              gap: 8px;
              color: var(--muted);
              font-size: 12px;
            }
            .live-dot {
              width: 8px;
              height: 8px;
              border-radius: 999px;
              background: var(--ready);
              box-shadow: 0 0 0 5px rgba(117, 227, 156, 0.09);
            }
            .note-header h1 {
              margin: 0;
              color: var(--text);
              font-size: clamp(28px, 5vw, 44px);
              font-weight: 620;
              line-height: 1.05;
            }
            .scratchpad {
              display: grid;
              min-height: 420px;
              padding: 10px 8px;
            }
            .scratchpad textarea {
              width: 100%;
              min-height: 420px;
              resize: vertical;
              border: 0;
              outline: 0;
              background: transparent;
              color: var(--text);
              font: inherit;
              font-size: 22px;
              line-height: 1.45;
            }
            .scratchpad textarea::placeholder {
              color: rgba(243, 245, 247, 0.34);
            }
            .transcript-toggle {
              display: flex;
              align-items: center;
              justify-content: space-between;
              width: calc(100% - 16px);
              margin: 0 8px;
              border: 1px solid var(--line);
              border-radius: 18px;
              padding: 13px 14px;
              background: rgba(255, 255, 255, 0.03);
              color: var(--text);
              font: inherit;
              font-size: 14px;
              cursor: pointer;
            }
            .transcript-count {
              color: var(--muted);
              font-size: 12px;
            }
            .transcript-shell {
              max-height: 42vh;
              overflow: auto;
              margin: 0 8px;
              border: 1px solid var(--line);
              border-radius: 18px;
              background: rgba(255, 255, 255, 0.025);
            }
            .transcript-shell[hidden] {
              display: none;
            }
            .transcript-shell .stream {
              padding: 0 12px 8px;
            }
            .recorder-dock {
              position: sticky;
              bottom: 0;
              display: grid;
              grid-template-columns: auto auto;
              gap: 12px;
              align-items: center;
              justify-content: space-between;
              margin: 0 0 4px;
              border: 1px solid var(--line);
              border-radius: 999px;
              padding: 12px 14px;
              background: rgba(43, 45, 45, 0.92);
              box-shadow: 0 18px 60px rgba(0, 0, 0, 0.32);
              backdrop-filter: blur(22px);
            }
            .recorder-left {
              display: flex;
              align-items: center;
              gap: 10px;
            }
            .record-dot {
              width: 12px;
              height: 12px;
              border-radius: 999px;
              background: #ff5f57;
              box-shadow: 0 0 0 6px rgba(255, 95, 87, 0.13);
            }
            .stop-square {
              width: 13px;
              height: 13px;
              border-radius: 3px;
              background: rgba(243, 245, 247, 0.72);
            }
            .waveform {
              display: flex;
              align-items: center;
              gap: 3px;
              min-width: 72px;
            }
            .waveform span {
              width: 3px;
              height: var(--h);
              border-radius: 999px;
              background: var(--ready);
              opacity: 0.88;
            }
            .live-pill {
              border-radius: 999px;
              padding: 5px 9px;
              background: rgba(117, 227, 156, 0.11);
              color: var(--ready);
              font-size: 12px;
              white-space: nowrap;
            }
            @media (prefers-color-scheme: light) {
              :root {
                --bg: #f4f0e8;
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
              .utterance {
                grid-template-columns: 50px minmax(0, 1fr);
                gap: 6px 8px;
              }
            }
          </style>
        </head>
        <body>
          <main class="live-note">
            <header class="note-header">
              <div class="note-topline">
                <span class="live-dot" aria-hidden="true"></span>
                <span id="status" title="\(escapedStatus)">\(escapedDisplayStatus)</span>
              </div>
              <h1 id="meeting-title">\(escapedTitle)</h1>
            </header>
            <section class="handoff" id="handoff" hidden>
              <p class="handoff-title">Transcript saved.</p>
            </section>
            <section class="scratchpad" aria-label="Meeting scratchpad">
              <textarea id="scratchpad" placeholder="Write notes" spellcheck="true"></textarea>
            </section>
            <button class="transcript-toggle" id="transcript-toggle" type="button" aria-expanded="false">
              <span>Transcript</span>
              <span class="transcript-count" id="source-summary">Waiting</span>
            </button>
            <section class="transcript-shell" id="transcript-shell" hidden>
              <section class="stream" id="transcript" aria-live="polite"></section>
            </section>
            <textarea class="hidden" id="initial-transcript" readonly>\(escapedTranscript)</textarea>
            <footer class="recorder-dock" aria-label="Live recording controls">
              <div class="recorder-left">
                <span class="record-dot" aria-hidden="true"></span>
                <div class="waveform" aria-hidden="true">
                  <span style="--h: 8px"></span>
                  <span style="--h: 14px"></span>
                  <span style="--h: 20px"></span>
                  <span style="--h: 12px"></span>
                  <span style="--h: 18px"></span>
                  <span style="--h: 9px"></span>
                  <span style="--h: 15px"></span>
                </div>
                <span class="stop-square" aria-hidden="true"></span>
              </div>
              <span class="live-pill">Live</span>
            </footer>
          </main>
          <script>
            const previewAuthToken = "\(escapedPreviewAuthToken)";
            function withPreviewAuthToken(url) {
              if (window.location.protocol === "file:" || !previewAuthToken) {
                return url;
              }
              const separator = url.includes("?") ? "&" : "?";
              return `${url}${separator}token=${encodeURIComponent(previewAuthToken)}`;
            }
            function cacheBusted(url) {
              const separator = url.includes("?") ? "&" : "?";
              return `${url}${separator}t=${Date.now()}`;
            }
            const stateURL = window.location.protocol === "file:" ? "state.json" : withPreviewAuthToken("/state.json");
            const transcriptURL = window.location.protocol === "file:" ? "live_transcript.md" : withPreviewAuthToken("/live_transcript.md");
            const statusElement = document.getElementById("status");
            const titleElement = document.getElementById("meeting-title");
            const sourceSummaryElement = document.getElementById("source-summary");
            const transcriptElement = document.getElementById("transcript");
            const initialTranscriptElement = document.getElementById("initial-transcript");
            const handoffElement = document.getElementById("handoff");
            const transcriptToggle = document.getElementById("transcript-toggle");
            const transcriptShell = document.getElementById("transcript-shell");
            const scratchpadElement = document.getElementById("scratchpad");
            const scratchpadKey = "transcripted-live-meeting-scratchpad";
            let lastTranscript = initialTranscriptElement.value;
            let transcriptOpen = false;

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

            function hasFinalTranscript(state) {
              return Boolean(state && state.finalTranscriptPath);
            }

            function friendlyStatus(state) {
              if (!state || !state.status) {
                return "Not recording";
              }

              if (state.status === "recording") {
                return "Recording locally";
              }

              if (state.status === "transcript_saved") {
                return "Transcript saved";
              }

              if (state.status === "stopped") {
                return "Waiting for transcript";
              }

              if (state.status === "cancelled") {
                return "Recording cancelled.";
              }

              if (state.status === "failed") {
                return "Needs attention";
              }

              return "Not recording";
            }

            function updateHandoff(state) {
              if (hasFinalTranscript(state)) {
                handoffElement.hidden = false;
              } else {
                handoffElement.hidden = true;
              }
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
              const snippetLabel = entries.length === 1 ? "1 snippet" : `${entries.length} snippets`;
              sourceSummaryElement.textContent = entries.length > 0 ? snippetLabel : "Empty";

              if (entries.length === 0) {
                transcriptElement.innerHTML = '<div class="empty-state">Waiting for live transcript text.</div>';
                return;
              }

              transcriptElement.innerHTML = entries.map((entry) => {
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

            transcriptToggle.addEventListener("click", () => {
              transcriptOpen = !transcriptOpen;
              transcriptShell.hidden = !transcriptOpen;
              transcriptToggle.setAttribute("aria-expanded", String(transcriptOpen));
              transcriptToggle.querySelector("span").textContent = transcriptOpen ? "Hide transcript" : "Transcript";
            });

            scratchpadElement.value = window.localStorage.getItem(scratchpadKey) || "";
            scratchpadElement.addEventListener("input", () => {
              window.localStorage.setItem(scratchpadKey, scratchpadElement.value);
            });

            async function refreshPreview() {
              const shouldFollow = transcriptOpen && isNearBottom();
              try {
                const [stateResponse, transcriptResponse] = await Promise.all([
                  fetch(cacheBusted(stateURL), { cache: "no-store" }),
                  fetch(cacheBusted(transcriptURL), { cache: "no-store" })
                ]);

                if (stateResponse.ok) {
                  const state = await stateResponse.json();
                  statusElement.textContent = friendlyStatus(state);
                  statusElement.title = `${state.status || ""} - ${state.streamingBackendStatus || ""}`;
                  titleElement.textContent = state.title || "Live Meeting";
                  updateHandoff(state);
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

    private static func javaScriptEscaped(_ text: String) -> String {
        text
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
            .replacingOccurrences(of: "\n", with: "\\n")
            .replacingOccurrences(of: "\r", with: "\\r")
    }

    private static func generatePreviewAuthToken() -> String {
        (0..<3)
            .map { _ in UUID().uuidString.replacingOccurrences(of: "-", with: "").lowercased() }
            .joined()
    }

    private static func isoString(_ date: Date) -> String {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter.string(from: date)
    }
}
