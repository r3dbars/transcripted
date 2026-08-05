import Foundation
import TranscriptedCaptureKit

private let logSuppressionLock = NSLock()
private var logSuppressionDepth = 0

enum ContextArtifactKind {
    case meeting
    case dictationDay
}

struct ContextArtifactFile {
    let url: URL
    let modDate: TimeInterval
    let kind: ContextArtifactKind
}

enum TranscriptLoader {
    static func load(_ url: URL) -> AgentTranscript? {
        loadMeeting(url)
    }

    static func loadMeeting(_ url: URL) -> AgentTranscript? {
        guard let content = CaptureMarkdown.readBoundedContents(of: url),
              let parsed = CaptureMarkdownParser.parseMeeting(from: content) else {
            log("Cannot read meeting markdown")
            return nil
        }

        return AgentTranscript(
            version: "2.0",
            recording: AgentRecording(
                date: parsed.datetime,
                durationSeconds: parsed.durationSeconds,
                droppedSegments: parsed.droppedSegments,
                engines: AgentEngines(
                    stt: parsed.sttEngine,
                    diarization: parsed.diarizationEngine
                )
            ),
            speakers: parsed.speakers.map { speaker in
                AgentSpeaker(
                    id: speaker.id,
                    persistentSpeakerId: speaker.persistentSpeakerId,
                    name: speaker.name,
                    confidence: speaker.confidence,
                    wordCount: speaker.wordCount,
                    speakingSeconds: speaker.speakingSeconds
                )
            },
            utterances: parsed.utterances.map { utterance in
                AgentUtterance(
                    start: utterance.start,
                    end: utterance.end,
                    speakerId: utterance.speakerId,
                    text: utterance.text
                )
            }
        )
    }

    /// Structured summary for a legacy saved meeting. It prefers an inline
    /// summary block, then falls back to a `<stem>.summary.md` sidecar so old
    /// artifacts remain readable. Current capture does not create new summaries.
    ///
    /// The sidecar branch is a legacy-compat fallback; a sidecar edited in
    /// isolation does not bump the parent transcript's mtime, so its items only
    /// refresh on the next reindex of the transcript itself.
    static func loadMeetingSummary(forTranscript url: URL) -> ParsedMeetingSummary? {
        if let content = CaptureMarkdown.readBoundedContents(of: url),
           let summary = CaptureSummaryParser.parse(from: content) {
            return summary
        }

        let sidecarURL = summarySidecarURL(forTranscript: url)
        if let content = CaptureMarkdown.readBoundedContents(of: sidecarURL),
           let summary = CaptureSummaryParser.parse(from: content) {
            return summary
        }

        return nil
    }

    /// Mirrors the legacy `<stem>.summary.md` sidecar convention used by old app artifacts:
    /// `<dir>/<stem>.summary.md` next to the transcript.
    static func summarySidecarURL(forTranscript url: URL) -> URL {
        let base = url.deletingPathExtension()
        return base
            .deletingLastPathComponent()
            .appendingPathComponent("\(base.lastPathComponent).summary")
            .appendingPathExtension("md")
    }

    static func loadDictationDay(_ url: URL) -> AgentDictationDay? {
        guard let content = CaptureMarkdown.readBoundedContents(of: url),
              let parsed = CaptureMarkdownParser.parseDictationDay(from: content, markdownURL: url) else {
            log("Cannot read dictation markdown")
            return nil
        }

        return AgentDictationDay(
            version: "2.0",
            captureType: parsed.captureType,
            date: parsed.date,
            markdownFilename: parsed.markdownFilename,
            entryCount: parsed.entryCount,
            wordCount: parsed.wordCount,
            entries: parsed.entries.map { entry in
                AgentDictationEntry(
                    id: entry.id,
                    createdAt: entry.createdAt,
                    title: entry.title,
                    text: entry.text,
                    sourceAppName: entry.sourceAppName,
                    sourceAppBundleId: entry.sourceAppBundleId,
                    delivery: entry.delivery,
                    wordCount: entry.wordCount,
                    characterCount: entry.characterCount
                )
            }
        )
    }

    static func artifactKind(for url: URL) -> ContextArtifactKind? {
        guard url.pathExtension == "md", CaptureMarkdown.looksLikeCaptureMarkdown(url) else { return nil }

        let filename = url.deletingPathExtension().lastPathComponent
        if filename.hasPrefix("Dictations_") {
            return .dictationDay
        }
        // Generated `<stem>.summary.md` sidecars carry frontmatter too, but they
        // are not meetings — they are read as a fallback summary source for their
        // parent transcript (see loadMeetingSummary). Indexing them as meetings
        // would create empty junk rows and double-index summary items.
        if filename.hasSuffix(".summary") {
            return nil
        }
        return .meeting
    }

    static func enumerateArtifacts(in directory: URL) -> [ContextArtifactFile] {
        let fm = FileManager.default
        let enumerationRoot = directory.resolvingSymlinksInPath().standardizedFileURL
        guard let files = try? fm.contentsOfDirectory(
            at: enumerationRoot,
            includingPropertiesForKeys: [.contentModificationDateKey]
        ) else {
            return []
        }

        return files.compactMap { url in
            guard case .valid(let safeURL) = PathSecurity.validateExistingFile(url, under: directory),
                  let kind = artifactKind(for: safeURL) else { return nil }
            let modDate = (try? safeURL.resourceValues(forKeys: [.contentModificationDateKey])
                .contentModificationDate?.timeIntervalSince1970) ?? 0
            return ContextArtifactFile(url: safeURL, modDate: modDate, kind: kind)
        }
    }

    static func speakerLookup(from transcript: AgentTranscript) -> [String: (name: String, persistentId: String?)] {
        var lookup: [String: (name: String, persistentId: String?)] = [:]
        for speaker in transcript.speakers {
            lookup[speaker.id] = (speaker.name, speaker.persistentSpeakerId)
        }
        return lookup
    }
}

/// Log to stderr (stdout is reserved for MCP JSON-RPC).
func log(_ message: String) {
    logSuppressionLock.lock()
    let isSuppressed = logSuppressionDepth > 0
    logSuppressionLock.unlock()

    guard !isSuppressed else { return }
    fputs("[transcripted-mcp] \(message)\n", stderr)
}

func withLogsSuppressed<T>(_ body: () throws -> T) rethrows -> T {
    logSuppressionLock.lock()
    logSuppressionDepth += 1
    logSuppressionLock.unlock()

    defer {
        logSuppressionLock.lock()
        logSuppressionDepth = max(0, logSuppressionDepth - 1)
        logSuppressionLock.unlock()
    }

    return try body()
}

enum MCPLogPrivacy {
    static func countBucket(_ count: Int) -> String {
        switch max(0, count) {
        case 0: return "0"
        case 1: return "1"
        case 2...10: return "2_to_10"
        case 11...100: return "11_to_100"
        case 101...1_000: return "101_to_1000"
        default: return "over_1000"
        }
    }
}

enum MCPStartupDiagnostics {
    enum Phase: String {
        case lexicalIndexReady = "lexical_index_ready"
        case transportReady = "transport_ready"
        case semanticIndexStarted = "semantic_index_started"
        case semanticIndexReady = "semantic_index_ready"
    }

    static func message(phase: Phase, elapsedSeconds: TimeInterval) -> String {
        "Startup phase=\(phase.rawValue) elapsed_bucket=\(elapsedBucket(elapsedSeconds))"
    }

    static func elapsedBucket(_ seconds: TimeInterval) -> String {
        switch max(0, seconds) {
        case ..<0.25: return "under_250ms"
        case ..<1: return "250ms_to_1s"
        case ..<5: return "1s_to_5s"
        case ..<15: return "5s_to_15s"
        case ..<30: return "15s_to_30s"
        case ..<60: return "30s_to_60s"
        default: return "over_60s"
        }
    }
}
