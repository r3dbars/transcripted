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
        guard let content = try? String(contentsOf: url, encoding: .utf8),
              let parsed = CaptureMarkdownParser.parseMeeting(from: content) else {
            log("Cannot read markdown meeting: \(url.lastPathComponent)")
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

    static func loadDictationDay(_ url: URL) -> AgentDictationDay? {
        guard let content = try? String(contentsOf: url, encoding: .utf8),
              let parsed = CaptureMarkdownParser.parseDictationDay(from: content, markdownURL: url) else {
            log("Cannot read markdown dictation day: \(url.lastPathComponent)")
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
