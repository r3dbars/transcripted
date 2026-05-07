import Foundation
import TranscriptedCaptureParsing

private typealias CaptureParser = TranscriptedCaptureMarkdownParser

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
              let document = CaptureParser.parseFrontmatter(from: content) else {
            log("Cannot read markdown meeting: \(url.lastPathComponent)")
            return nil
        }

        let entries = CaptureParser.parseTranscriptEntries(from: document.body)
        let speakerMetadata = CaptureParser.parseSpeakerMetadata(from: content)
        let speakerMetadataByName = CaptureParser.uniqueSpeakerMetadataByNormalizedName(speakerMetadata)

        var generatedIDsByLabel: [String: String] = [:]
        var nextMicId = 0
        var nextSystemId = 0
        var utterances: [AgentUtterance] = []
        utterances.reserveCapacity(entries.count)

        for entry in entries {
            let normalizedLabel = CaptureParser.normalizeSpeakerLabel(entry.label)
            let speakerId: String

            if entry.source == "Mic" {
                if let existing = generatedIDsByLabel["mic:\(normalizedLabel)"] {
                    speakerId = existing
                } else {
                    speakerId = "mic_\(nextMicId)"
                    generatedIDsByLabel["mic:\(normalizedLabel)"] = speakerId
                    nextMicId += 1
                }
            } else {
                if let metadata = speakerMetadataByName[normalizedLabel] {
                    speakerId = "system_\(metadata.rawId)"
                } else if let existing = generatedIDsByLabel["system:\(normalizedLabel)"] {
                    speakerId = existing
                } else {
                    speakerId = "system_\(nextSystemId)"
                    generatedIDsByLabel["system:\(normalizedLabel)"] = speakerId
                    nextSystemId += 1
                }
            }

            let estimatedEnd = CaptureParser.estimatedEndSeconds(
                for: entry,
                next: utterances.count < entries.count - 1 ? entries[utterances.count + 1] : nil
            )
            utterances.append(AgentUtterance(
                start: entry.startSeconds,
                end: estimatedEnd,
                speakerId: speakerId,
                text: entry.text
            ))
        }

        let groupedUtterances = Dictionary(grouping: zip(entries, utterances), by: { $0.1.speakerId })
        var speakers: [AgentSpeaker] = []

        for (speakerId, grouped) in groupedUtterances.sorted(by: { $0.key < $1.key }) {
            let displayName = grouped.first?.0.label ?? speakerId
            let metadata = speakerId.hasPrefix("system_")
                ? speakerMetadata.first(where: {
                    "system_\($0.rawId)" == speakerId
                        || CaptureParser.normalizeSpeakerLabel($0.name) == CaptureParser.normalizeSpeakerLabel(displayName)
                })
                : nil
            let wordCount = grouped.reduce(0) { $0 + $1.0.text.split(whereSeparator: \.isWhitespace).count }
            let speakingSeconds = grouped.reduce(0.0) { $0 + max(0, $1.1.end - $1.1.start) }

            speakers.append(AgentSpeaker(
                id: speakerId,
                persistentSpeakerId: metadata?.persistentSpeakerId,
                name: displayName,
                confidence: metadata?.confidence,
                wordCount: wordCount,
                speakingSeconds: (speakingSeconds * 10).rounded() / 10
            ))
        }

        let date = document.values["date"] ?? "1970-01-01"
        let time = document.values["time"] ?? "00:00:00"
        let datetime = "\(date)T\(time)"
        let durationSeconds = CaptureParser.parseDurationSeconds(document.values["duration"])
        let droppedSegments = Int(document.values["dropped_segments"] ?? "") ?? 0

        return AgentTranscript(
            version: "2.0",
            recording: AgentRecording(
                date: datetime,
                durationSeconds: durationSeconds,
                droppedSegments: droppedSegments,
                engines: AgentEngines(
                    stt: document.values["transcription_engine"] ?? "unknown",
                    diarization: document.values["diarization_engine"] ?? "unknown"
                )
            ),
            speakers: speakers,
            utterances: utterances
        )
    }

    static func loadDictationDay(_ url: URL) -> AgentDictationDay? {
        guard let content = try? String(contentsOf: url, encoding: .utf8),
              let document = CaptureParser.parseFrontmatter(from: content) else {
            log("Cannot read markdown dictation day: \(url.lastPathComponent)")
            return nil
        }

        let entries = CaptureParser.parseDictationEntries(from: document.body)
            .map(AgentDictationEntry.init(parsed:))
        let date = document.values["date"] ?? url.deletingPathExtension().lastPathComponent.replacingOccurrences(of: "Dictations_", with: "")

        return AgentDictationDay(
            version: "2.0",
            captureType: document.values["capture_type"] ?? "dictation_day",
            date: date,
            markdownFilename: url.lastPathComponent,
            entryCount: entries.count,
            wordCount: entries.reduce(0) { $0 + $1.wordCount },
            entries: entries
        )
    }

    static func artifactKind(for url: URL) -> ContextArtifactKind? {
        guard url.pathExtension == "md", CaptureParser.looksLikeCaptureMarkdown(url) else { return nil }

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

private extension AgentDictationEntry {
    init(parsed: ParsedCaptureDictationEntry) {
        self.init(
            id: parsed.id,
            createdAt: parsed.createdAt,
            title: parsed.title,
            text: parsed.text,
            sourceAppName: parsed.sourceAppName,
            sourceAppBundleId: parsed.sourceAppBundleId,
            delivery: parsed.delivery,
            wordCount: parsed.wordCount,
            characterCount: parsed.characterCount
        )
    }
}

/// Log to stderr (stdout is reserved for MCP JSON-RPC).
func log(_ message: String) {
    fputs("[transcripted-mcp] \(message)\n", stderr)
}
