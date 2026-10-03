import Foundation
import TranscriptedCaptureKit

private let logSuppressionLock = NSLock()
private var logSuppressionDepth = 0

enum ContextArtifactKind {
    case meeting
    case dictationDay
    case writingDay
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
                    diarization: parsed.diarizationEngine,
                    voiceprintModel: parsed.voiceprintModel
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
        loadDictationDayWithContent(url)?.day
    }

    static func loadDictationDayWithContent(_ url: URL) -> (day: AgentDictationDay, content: String)? {
        guard let content = CaptureMarkdown.readBoundedContents(of: url),
              let parsed = CaptureMarkdownParser.parseDictationDay(from: content, markdownURL: url) else {
            log("Cannot read dictation markdown")
            return nil
        }

        let day = AgentDictationDay(
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
        return (day, content)
    }

    static func loadWritingDay(_ url: URL) -> AgentWritingDay? {
        loadWritingDayWithContent(url)?.day
    }

    static func loadWritingDayWithContent(_ url: URL) -> (day: AgentWritingDay, content: String)? {
        guard let content = CaptureMarkdown.readBoundedContents(of: url),
              let parsed = CaptureMarkdownParser.parseWritingDay(from: content, markdownURL: url) else {
            log("Cannot read writing markdown")
            return nil
        }

        let day = AgentWritingDay(
            version: "1.0",
            captureType: parsed.captureType,
            date: parsed.date,
            formatVersion: parsed.formatVersion,
            markdownFilename: parsed.markdownFilename,
            entryCount: parsed.entryCount,
            wordCount: parsed.wordCount,
            acceptedWordCount: parsed.acceptedWordCount,
            entries: parsed.entries.map { entry in
                AgentWritingEntry(
                    id: entry.id,
                    createdAt: entry.createdAt,
                    title: entry.title,
                    text: entry.text,
                    sourceAppName: entry.sourceAppName,
                    sourceAppBundleId: entry.sourceAppBundleId,
                    wordCount: entry.wordCount,
                    characterCount: entry.characterCount,
                    acceptedWordCount: entry.acceptedWordCount
                )
            }
        )
        return (day, content)
    }

    static func artifactKind(for url: URL) -> ContextArtifactKind? {
        guard url.pathExtension == "md", let captureKind = CaptureMarkdown.captureKind(of: url) else { return nil }

        // Writing is checked first (by `Writing_` prefix or `capture_type:
        // writing_day`): in the TRANSCRIPTED_DATA_DIR flat-folder fallback,
        // meetings, dictations, and writing share one directory, and a writing
        // day file has frontmatter, so the meeting default below would index it
        // as an empty meeting.
        switch captureKind {
        case .writingDay:
            return .writingDay
        case .dictationDay:
            return .dictationDay
        case .meeting:
            break
        }

        let filename = url.deletingPathExtension().lastPathComponent
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

        var seenKinds: [String: ArtifactKindCache.Entry] = [:]
        let previousKinds = ArtifactKindCache.shared.entries(for: enumerationRoot.path)
        let artifacts: [ContextArtifactFile] = files.compactMap { url in
            guard case .valid(let safeURL) = PathSecurity.validateExistingFile(url, under: directory) else {
                return nil
            }
            let kind: ContextArtifactKind
            let path = safeURL.standardizedFileURL.path
            let identity = ArtifactKindCache.FileIdentity(path: path)
            if let identity, let cached = previousKinds[path], cached.identity == identity {
                kind = cached.kind
                seenKinds[path] = cached
            } else {
                guard let classified = artifactKind(for: safeURL) else { return nil }
                kind = classified
                // Only a positive classification is cached. A nil can mean a
                // failed read as well as "not a capture file", so it is
                // re-checked next pass, exactly as before the cache existed.
                if let identity {
                    seenKinds[path] = ArtifactKindCache.Entry(identity: identity, kind: classified)
                }
            }
            let modDate = (try? safeURL.resourceValues(forKeys: [.contentModificationDateKey])
                .contentModificationDate?.timeIntervalSince1970) ?? 0
            return ContextArtifactFile(url: safeURL, modDate: modDate, kind: kind)
        }
        ArtifactKindCache.shared.replaceEntries(for: enumerationRoot.path, with: seenKinds)
        return artifacts
    }

    /// Filename-derived display title for a meeting with no better title source:
    /// `Call_2026-04-07_14-30` becomes `2026-04-07 14:30`.
    static func fallbackMeetingTitle(forFilename filename: String) -> String {
        filename
            .replacingOccurrences(of: "Call_", with: "")
            .replacingOccurrences(of: "_", with: " ")
            .replacingOccurrences(of: "-", with: ":")
    }

    static func speakerLookup(from transcript: AgentTranscript) -> [String: (name: String, persistentId: String?)] {
        var lookup: [String: (name: String, persistentId: String?)] = [:]
        for speaker in transcript.speakers {
            lookup[speaker.id] = (speaker.name, speaker.persistentSpeakerId)
        }
        return lookup
    }
}

/// Per-process memo of `TranscriptLoader.artifactKind(for:)` so a reconcile
/// pass over an unchanged library is stat-only instead of re-reading every
/// meeting's frontmatter prefix. An entry is reused only while the file's
/// device, inode, size, mtime and ctime all match. ctime moves on any content
/// or attribute change, even when mtime is restored afterwards, and an atomic
/// rewrite gets a new inode. Each directory's entries are replaced wholesale on
/// every enumeration, so deleted files drop out. enumerateArtifacts runs on
/// several watcher queues at once, hence the lock.
final class ArtifactKindCache: @unchecked Sendable {
    struct FileIdentity: Equatable {
        let device: Int64
        let inode: UInt64
        let size: Int64
        let mtimeSeconds: Int
        let mtimeNanoseconds: Int
        let ctimeSeconds: Int
        let ctimeNanoseconds: Int

        /// nil when the file can't be stat'ed; such files are never cached.
        init?(path: String) {
            var info = stat()
            guard lstat(path, &info) == 0, (info.st_mode & S_IFMT) == S_IFREG else { return nil }
            device = Int64(info.st_dev)
            inode = UInt64(info.st_ino)
            size = Int64(info.st_size)
            mtimeSeconds = Int(info.st_mtimespec.tv_sec)
            mtimeNanoseconds = Int(info.st_mtimespec.tv_nsec)
            ctimeSeconds = Int(info.st_ctimespec.tv_sec)
            ctimeNanoseconds = Int(info.st_ctimespec.tv_nsec)
        }
    }

    struct Entry {
        let identity: FileIdentity
        let kind: ContextArtifactKind
    }

    static let shared = ArtifactKindCache()

    private let lock = NSLock()
    private var entriesByDirectory: [String: [String: Entry]] = [:]

    func entries(for directoryPath: String) -> [String: Entry] {
        lock.lock()
        defer { lock.unlock() }
        return entriesByDirectory[directoryPath] ?? [:]
    }

    func replaceEntries(for directoryPath: String, with entries: [String: Entry]) {
        lock.lock()
        defer { lock.unlock() }
        if entries.isEmpty {
            entriesByDirectory.removeValue(forKey: directoryPath)
        } else {
            entriesByDirectory[directoryPath] = entries
        }
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
