import Foundation

enum ContextSidecarKind {
    case meeting
    case dictationDay
}

struct ContextSidecarFile {
    let url: URL
    let modDate: TimeInterval
    let kind: ContextSidecarKind
}

private struct MarkdownFrontmatter {
    let values: [String: String]
    let body: String
}

private struct ParsedTranscriptEntry {
    let timestamp: String
    let startSeconds: Double
    let source: String
    let label: String
    let text: String
}

private struct ParsedFrontmatterSpeaker {
    let rawId: String
    let persistentSpeakerId: String?
    let name: String
    let confidence: String?
}

enum TranscriptLoader {
    static func load(_ url: URL) -> AgentTranscript? {
        loadMeeting(url)
    }

    static func loadMeeting(_ url: URL) -> AgentTranscript? {
        guard let content = try? String(contentsOf: url, encoding: .utf8),
              let document = parseFrontmatter(from: content) else {
            log("Cannot read markdown meeting: \(url.lastPathComponent)")
            return nil
        }

        let entries = parseTranscriptEntries(from: document.body)
        let speakerMetadata = parseSpeakerMetadata(from: content)
        let speakerMetadataByName = uniqueSpeakerMetadataByNormalizedName(speakerMetadata)

        var generatedIDsByLabel: [String: String] = [:]
        var nextMicId = 0
        var nextSystemId = 0
        var utterances: [AgentUtterance] = []
        utterances.reserveCapacity(entries.count)

        for entry in entries {
            let normalizedLabel = normalizeSpeakerLabel(entry.label)
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

            let estimatedEnd = estimatedEndSeconds(for: entry, next: utterances.count < entries.count - 1 ? entries[utterances.count + 1] : nil)
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
                ? speakerMetadata.first(where: { "system_\($0.rawId)" == speakerId || normalizeSpeakerLabel($0.name) == normalizeSpeakerLabel(displayName) })
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
        let durationSeconds = parseDurationSeconds(document.values["duration"])
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
              let document = parseFrontmatter(from: content) else {
            log("Cannot read markdown dictation day: \(url.lastPathComponent)")
            return nil
        }

        let entries = parseDictationEntries(from: document.body)
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

    static func sidecarKind(for url: URL) -> ContextSidecarKind? {
        guard url.pathExtension == "md" else { return nil }

        let filename = url.deletingPathExtension().lastPathComponent
        if filename.hasPrefix("Dictations_") {
            return .dictationDay
        }
        return .meeting
    }

    static func enumerateSidecars(in directory: URL) -> [ContextSidecarFile] {
        let fm = FileManager.default
        guard let files = try? fm.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: [.contentModificationDateKey]
        ) else {
            return []
        }

        return files.compactMap { url in
            guard case .valid(let safeURL) = PathSecurity.validateExistingFile(url, under: directory),
                  let kind = sidecarKind(for: safeURL) else { return nil }
            let modDate = (try? safeURL.resourceValues(forKeys: [.contentModificationDateKey])
                .contentModificationDate?.timeIntervalSince1970) ?? 0
            return ContextSidecarFile(url: safeURL, modDate: modDate, kind: kind)
        }
    }

    static func speakerLookup(from transcript: AgentTranscript) -> [String: (name: String, persistentId: String?)] {
        var lookup: [String: (name: String, persistentId: String?)] = [:]
        for speaker in transcript.speakers {
            lookup[speaker.id] = (speaker.name, speaker.persistentSpeakerId)
        }
        return lookup
    }

    private static func parseFrontmatter(from content: String) -> MarkdownFrontmatter? {
        guard content.hasPrefix("---\n"),
              let endRange = content.range(
                of: "\n---\n",
                range: content.index(content.startIndex, offsetBy: 4)..<content.endIndex
              ) else {
            return nil
        }

        let frontmatterText = String(content[content.index(content.startIndex, offsetBy: 4)..<endRange.lowerBound])
        var values: [String: String] = [:]
        for line in frontmatterText.components(separatedBy: "\n") {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            guard !trimmed.hasPrefix("- "),
                  let separator = trimmed.firstIndex(of: ":") else { continue }
            let key = String(trimmed[..<separator]).trimmingCharacters(in: .whitespaces)
            let value = String(trimmed[trimmed.index(after: separator)...])
                .trimmingCharacters(in: .whitespacesAndNewlines)
                .trimmingCharacters(in: CharacterSet(charactersIn: "\""))
            values[key] = value
        }

        return MarkdownFrontmatter(values: values, body: String(content[endRange.upperBound...]))
    }

    private static func parseSpeakerMetadata(from content: String) -> [ParsedFrontmatterSpeaker] {
        guard parseFrontmatter(from: content) != nil,
              content.range(of: "\nspeakers:\n") != nil else {
            return []
        }

        let frontmatterEnd = content.range(
            of: "\n---\n",
            range: content.index(content.startIndex, offsetBy: 4)..<content.endIndex
        )?.lowerBound ?? content.endIndex
        let frontmatter = String(content[content.startIndex..<frontmatterEnd])
        guard let sectionRange = frontmatter.range(of: "speakers:\n") else { return [] }
        let speakerLines = frontmatter[sectionRange.upperBound...].components(separatedBy: "\n")

        var speakers: [ParsedFrontmatterSpeaker] = []
        var currentId: String?
        var currentPersistentId: String?
        var currentName: String?
        var currentConfidence: String?

        func flush() {
            if let currentId, let currentName {
                speakers.append(ParsedFrontmatterSpeaker(
                    rawId: currentId,
                    persistentSpeakerId: currentPersistentId,
                    name: currentName,
                    confidence: currentConfidence
                ))
            }
            currentId = nil
            currentPersistentId = nil
            currentName = nil
            currentConfidence = nil
        }

        for rawLine in speakerLines {
            let trimmed = rawLine.trimmingCharacters(in: .whitespaces)
            if trimmed.hasPrefix("- id:") {
                flush()
                currentId = trimmed
                    .replacingOccurrences(of: "- id:", with: "")
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                    .trimmingCharacters(in: CharacterSet(charactersIn: "\""))
            } else if trimmed.hasPrefix("db_id:") {
                currentPersistentId = trimmed
                    .replacingOccurrences(of: "db_id:", with: "")
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                    .trimmingCharacters(in: CharacterSet(charactersIn: "\""))
            } else if trimmed.hasPrefix("name:") {
                currentName = trimmed
                    .replacingOccurrences(of: "name:", with: "")
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                    .trimmingCharacters(in: CharacterSet(charactersIn: "\""))
            } else if trimmed.hasPrefix("confidence:") {
                currentConfidence = trimmed
                    .replacingOccurrences(of: "confidence:", with: "")
                    .trimmingCharacters(in: .whitespacesAndNewlines)
            } else if !trimmed.hasPrefix("-"), !trimmed.hasPrefix("db_id:"), !trimmed.hasPrefix("name:"), !trimmed.hasPrefix("confidence:"), !trimmed.hasPrefix("source:"), !trimmed.isEmpty {
                break
            }
        }
        flush()
        return speakers
    }

    private static func uniqueSpeakerMetadataByNormalizedName(
        _ speakers: [ParsedFrontmatterSpeaker]
    ) -> [String: ParsedFrontmatterSpeaker] {
        var grouped: [String: [ParsedFrontmatterSpeaker]] = [:]
        for speaker in speakers {
            grouped[normalizeSpeakerLabel(speaker.name), default: []].append(speaker)
        }

        var unique: [String: ParsedFrontmatterSpeaker] = [:]
        for (name, matches) in grouped where matches.count == 1 {
            unique[name] = matches[0]
        }
        return unique
    }

    private static func parseTranscriptEntries(from body: String) -> [ParsedTranscriptEntry] {
        if let range = body.range(of: "## Transcript\n\n") {
            let transcriptBody = String(body[range.upperBound...])
            let chunks = transcriptBody
                .components(separatedBy: "\n\n")
                .filter { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
            let entries = chunks.compactMap(parseStyledTranscriptEntry)
            if !entries.isEmpty { return entries }
        }

        if let range = body.range(of: "## Full Transcript\n\n") {
            let transcriptBody = String(body[range.upperBound...])
            return transcriptBody
                .components(separatedBy: "\n")
                .compactMap(parseLegacyTranscriptLine)
        }

        return body.components(separatedBy: "\n").compactMap(parseLegacyTranscriptLine)
    }

    private static func parseLegacyTranscriptLine(_ line: String) -> ParsedTranscriptEntry? {
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        guard trimmed.hasPrefix("["),
              let timestampEnd = trimmed.firstIndex(of: "]") else {
            return nil
        }

        let timestamp = String(trimmed[trimmed.index(after: trimmed.startIndex)..<timestampEnd])
        let sourceStart = trimmed.index(timestampEnd, offsetBy: 3)
        guard let labelEnd = trimmed.range(of: "] ", range: sourceStart..<trimmed.endIndex) else {
            return nil
        }

        let sourceLabel = trimmed[sourceStart..<labelEnd.lowerBound]
        guard let separator = sourceLabel.firstIndex(of: "/") else { return nil }
        let source = String(sourceLabel[..<separator])
        let label = unwrapSpeakerLabel(String(sourceLabel[sourceLabel.index(after: separator)...]))
        let text = String(trimmed[labelEnd.upperBound...]).trimmingCharacters(in: .whitespacesAndNewlines)
        return ParsedTranscriptEntry(
            timestamp: timestamp,
            startSeconds: parseTimestampSeconds(timestamp),
            source: source,
            label: label,
            text: text
        )
    }

    private static func parseStyledTranscriptEntry(_ chunk: String) -> ParsedTranscriptEntry? {
        let lines = chunk.components(separatedBy: "\n").filter { !$0.isEmpty }
        guard let header = lines.first else { return nil }
        let normalizedHeader = header
            .replacingOccurrences(of: "**", with: "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard let regex = try? NSRegularExpression(pattern: #"^([0-9:]+)\s+\[(.+?)\]$"#) else {
            return nil
        }
        let nsHeader = normalizedHeader as NSString
        let range = NSRange(location: 0, length: nsHeader.length)
        guard let match = regex.firstMatch(in: normalizedHeader, range: range),
              match.numberOfRanges >= 3 else {
            return nil
        }
        let timestamp = nsHeader.substring(with: match.range(at: 1))
        let sourceLabel = nsHeader.substring(with: match.range(at: 2))
        guard let separator = sourceLabel.firstIndex(of: "/") else { return nil }

        let source = String(sourceLabel[..<separator])
        let label = unwrapSpeakerLabel(String(sourceLabel[sourceLabel.index(after: separator)...]))
        let text = lines.dropFirst().joined(separator: " ").trimmingCharacters(in: .whitespacesAndNewlines)
        return ParsedTranscriptEntry(
            timestamp: timestamp,
            startSeconds: parseTimestampSeconds(timestamp),
            source: source,
            label: label,
            text: text
        )
    }

    private static func parseDictationEntries(from body: String) -> [AgentDictationEntry] {
        let lines = body.components(separatedBy: "\n")
        var sections: [String] = []
        var currentSection: [String] = []

        for line in lines {
            if line.hasPrefix("## ") {
                if !currentSection.isEmpty {
                    sections.append(currentSection.joined(separator: "\n"))
                }
                currentSection = [line]
            } else if !currentSection.isEmpty {
                currentSection.append(line)
            }
        }

        if !currentSection.isEmpty {
            sections.append(currentSection.joined(separator: "\n"))
        }

        return sections.compactMap { rawSection in
            let section = rawSection
            let lines = section.components(separatedBy: "\n")
            guard let heading = lines.first, heading.hasPrefix("## ") else { return nil }
            let title = heading.replacingOccurrences(of: "## ", with: "")
                .components(separatedBy: " - ")
                .dropFirst()
                .joined(separator: " - ")

            var entryId = ""
            var createdAt = ""
            var sourceAppName = "Unknown"
            var sourceAppBundleId: String?
            var delivery = "failed"
            var wordCount = 0
            var characterCount = 0
            var bodyLines: [String] = []
            var inBody = false
            var sawMetadata = false

            for line in lines.dropFirst() {
                let trimmed = line.trimmingCharacters(in: .whitespaces)
                if trimmed.isEmpty {
                    if !inBody, sawMetadata {
                        inBody = true
                    } else if inBody {
                        bodyLines.append("")
                    }
                    continue
                }

                if inBody {
                    bodyLines.append(line)
                    continue
                }

                if trimmed.hasPrefix("Entry ID:") {
                    sawMetadata = true
                    entryId = trimmed.replacingOccurrences(of: "Entry ID:", with: "")
                        .trimmingCharacters(in: .whitespacesAndNewlines)
                        .trimmingCharacters(in: CharacterSet(charactersIn: "`"))
                } else if trimmed.hasPrefix("Captured:") {
                    sawMetadata = true
                    createdAt = trimmed.replacingOccurrences(of: "Captured:", with: "")
                        .trimmingCharacters(in: .whitespacesAndNewlines)
                } else if trimmed.hasPrefix("Source app:") {
                    sawMetadata = true
                    sourceAppName = trimmed.replacingOccurrences(of: "Source app:", with: "")
                        .trimmingCharacters(in: .whitespacesAndNewlines)
                } else if trimmed.hasPrefix("Bundle ID:") {
                    sawMetadata = true
                    sourceAppBundleId = trimmed.replacingOccurrences(of: "Bundle ID:", with: "")
                        .trimmingCharacters(in: .whitespacesAndNewlines)
                        .trimmingCharacters(in: CharacterSet(charactersIn: "`"))
                } else if trimmed.hasPrefix("Delivery:") {
                    sawMetadata = true
                    delivery = trimmed.replacingOccurrences(of: "Delivery:", with: "")
                        .trimmingCharacters(in: .whitespacesAndNewlines)
                } else if trimmed.hasPrefix("Words:") {
                    sawMetadata = true
                    wordCount = Int(trimmed.replacingOccurrences(of: "Words:", with: "").trimmingCharacters(in: .whitespacesAndNewlines)) ?? 0
                } else if trimmed.hasPrefix("Characters:") {
                    sawMetadata = true
                    characterCount = Int(trimmed.replacingOccurrences(of: "Characters:", with: "").trimmingCharacters(in: .whitespacesAndNewlines)) ?? 0
                } else if trimmed.hasPrefix("Timestamp:") {
                    sawMetadata = true
                    // Backward compatibility with pre-refactor dictation markdown.
                    createdAt = trimmed.replacingOccurrences(of: "Timestamp:", with: "")
                        .trimmingCharacters(in: .whitespacesAndNewlines)
                } else if !sawMetadata {
                    inBody = true
                    bodyLines.append(line)
                }
            }

            let text = bodyLines.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
            let finalWordCount = wordCount == 0 ? text.split(whereSeparator: \.isWhitespace).count : wordCount
            let finalCharacterCount = characterCount == 0 ? text.count : characterCount
            let finalEntryId = entryId.isEmpty ? "dictation-\(UUID().uuidString)" : entryId
            let finalCreatedAt = createdAt.isEmpty ? "1970-01-01T00:00:00Z" : createdAt

            return AgentDictationEntry(
                id: finalEntryId,
                createdAt: finalCreatedAt,
                title: title.isEmpty ? heading.replacingOccurrences(of: "## ", with: "") : title,
                text: text,
                sourceAppName: sourceAppName,
                sourceAppBundleId: sourceAppBundleId,
                delivery: delivery,
                wordCount: finalWordCount,
                characterCount: finalCharacterCount
            )
        }
        .sorted { $0.createdAt < $1.createdAt }
    }

    private static func estimatedEndSeconds(for entry: ParsedTranscriptEntry, next: ParsedTranscriptEntry?) -> Double {
        if let next, next.startSeconds > entry.startSeconds {
            return next.startSeconds
        }
        let estimatedDuration = max(1.0, min(20.0, Double(entry.text.split(whereSeparator: \.isWhitespace).count) / 2.5))
        return entry.startSeconds + estimatedDuration
    }

    private static func parseDurationSeconds(_ rawDuration: String?) -> Int {
        let components = (rawDuration ?? "").split(separator: ":").compactMap { Int($0) }
        switch components.count {
        case 2:
            return components[0] * 60 + components[1]
        case 3:
            return components[0] * 3600 + components[1] * 60 + components[2]
        default:
            return 0
        }
    }

    private static func parseTimestampSeconds(_ timestamp: String) -> Double {
        let components = timestamp.split(separator: ":").compactMap { Double($0) }
        switch components.count {
        case 2:
            return components[0] * 60 + components[1]
        case 3:
            return components[0] * 3600 + components[1] * 60 + components[2]
        default:
            return 0
        }
    }

    private static func unwrapSpeakerLabel(_ label: String) -> String {
        let trimmed = label.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.hasPrefix("[["), trimmed.hasSuffix("]]") {
            return String(trimmed.dropFirst(2).dropLast(2))
        }
        return trimmed
    }

    private static func normalizeSpeakerLabel(_ label: String) -> String {
        unwrapSpeakerLabel(label).trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    }
}

/// Log to stderr (stdout is reserved for MCP JSON-RPC).
func log(_ message: String) {
    fputs("[transcripted-mcp] \(message)\n", stderr)
}
