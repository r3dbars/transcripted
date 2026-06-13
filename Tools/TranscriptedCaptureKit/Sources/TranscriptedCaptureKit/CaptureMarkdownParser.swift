import Foundation

/// YAML frontmatter values plus the Markdown body that follows it.
public struct ParsedCaptureDocument {
    public let values: [String: String]
    public let body: String
}

/// Parsed meeting transcript. Carries the superset of fields the standalone
/// tools need; each tool maps this into its own output models.
public struct ParsedMeetingCapture {
    public struct Speaker {
        public let id: String
        public let name: String
        public let persistentSpeakerId: String?
        public let confidence: String?
        public let wordCount: Int
        public let speakingSeconds: Double
    }

    public struct Utterance {
        public let start: Double
        public let end: Double
        public let speakerId: String
        public let text: String
    }

    /// "YYYY-MM-DDTHH:MM:SS" assembled from the frontmatter date and time.
    public let datetime: String
    public let durationSeconds: Int
    public let droppedSegments: Int
    public let sttEngine: String
    public let diarizationEngine: String
    public let speakers: [Speaker]
    public let utterances: [Utterance]
}

/// Parsed dictation day file.
public struct ParsedDictationDayCapture {
    public struct Entry {
        public let id: String
        public let createdAt: String
        public let title: String
        public let text: String
        public let sourceAppName: String
        public let sourceAppBundleId: String?
        public let delivery: String
        public let wordCount: Int
        public let characterCount: Int
    }

    public let captureType: String
    public let date: String
    public let markdownFilename: String
    public let entryCount: Int
    public let wordCount: Int
    /// Sorted ascending by `createdAt`.
    public let entries: [Entry]
}

/// Shared parser for Transcripted capture Markdown (meeting transcripts and
/// dictation day files). Single source of truth for TranscriptedCLI and
/// TranscriptedMCP.
public enum CaptureMarkdownParser {
    private struct ParsedTranscriptEntry {
        let timestamp: String
        let startSeconds: Double
        let source: String
        let label: String
        let text: String
    }

    private struct ParsedFrontmatterSpeaker {
        let rawId: String
        let channel: String?
        let name: String
        let persistentSpeakerId: String?
        let confidence: String?
    }

    // MARK: - Frontmatter

    public static func parseFrontmatter(from content: String) -> ParsedCaptureDocument? {
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

        return ParsedCaptureDocument(values: values, body: String(content[endRange.upperBound...]))
    }

    // MARK: - Meetings

    public static func parseMeeting(from content: String) -> ParsedMeetingCapture? {
        guard let document = parseFrontmatter(from: content) else { return nil }

        let entries = parseTranscriptEntries(from: document.body)
        let speakerMetadata = parseFrontmatterSpeakers(from: content)
        let micSpeakerMetadataByName = uniqueSpeakerMetadataByNormalizedName(
            speakerMetadata,
            channel: "mic",
            includeChannelless: false
        )
        let systemSpeakerMetadataByName = uniqueSpeakerMetadataByNormalizedName(
            speakerMetadata,
            channel: "system",
            includeChannelless: true
        )
        let speakerMetadataByScopedId = scopedSpeakerMetadataById(speakerMetadata)
        let reservedSpeakerIds = Set(speakerMetadata.compactMap(reservedSpeakerId))

        var generatedIDsByLabel: [String: String] = [:]
        var assignedSpeakerIds = reservedSpeakerIds
        var nextMicId = 0
        var nextSystemId = 0
        var utterances: [ParsedMeetingCapture.Utterance] = []
        utterances.reserveCapacity(entries.count)

        for index in entries.indices {
            let entry = entries[index]
            let normalizedLabel = normalizeSpeakerLabel(entry.label)
            let speakerId: String

            if entry.source == "Mic" {
                if let metadata = micSpeakerMetadataByName[normalizedLabel] {
                    speakerId = "mic_\(metadata.rawId)"
                } else if let existing = generatedIDsByLabel["mic:\(normalizedLabel)"] {
                    speakerId = existing
                } else {
                    while assignedSpeakerIds.contains("mic_\(nextMicId)") {
                        nextMicId += 1
                    }
                    speakerId = "mic_\(nextMicId)"
                    generatedIDsByLabel["mic:\(normalizedLabel)"] = speakerId
                    nextMicId += 1
                }
            } else if let metadata = systemSpeakerMetadataByName[normalizedLabel] {
                speakerId = "system_\(metadata.rawId)"
            } else if let existing = generatedIDsByLabel["system:\(normalizedLabel)"] {
                speakerId = existing
            } else {
                while assignedSpeakerIds.contains("system_\(nextSystemId)") {
                    nextSystemId += 1
                }
                speakerId = "system_\(nextSystemId)"
                generatedIDsByLabel["system:\(normalizedLabel)"] = speakerId
                nextSystemId += 1
            }
            assignedSpeakerIds.insert(speakerId)

            let nextEntry = index + 1 < entries.count ? entries[index + 1] : nil
            utterances.append(ParsedMeetingCapture.Utterance(
                start: entry.startSeconds,
                end: estimatedEndSeconds(for: entry, next: nextEntry),
                speakerId: speakerId,
                text: entry.text
            ))
        }

        let grouped = Dictionary(grouping: zip(entries, utterances), by: { $0.1.speakerId })
        let speakers = grouped.keys.sorted().map { speakerId -> ParsedMeetingCapture.Speaker in
            let groupedUtterances = grouped[speakerId] ?? []
            let displayName = groupedUtterances.first?.0.label ?? speakerId
            let normalizedDisplayName = normalizeSpeakerLabel(displayName)
            let metadata: ParsedFrontmatterSpeaker?
            if let exactMetadata = speakerMetadataByScopedId[speakerId] {
                metadata = exactMetadata
            } else if speakerId.hasPrefix("mic_") {
                metadata = micSpeakerMetadataByName[normalizedDisplayName]
            } else if speakerId.hasPrefix("system_") {
                metadata = systemSpeakerMetadataByName[normalizedDisplayName]
            } else {
                metadata = nil
            }
            let wordCount = groupedUtterances.reduce(0) { $0 + $1.0.text.split(whereSeparator: \.isWhitespace).count }
            let speakingSeconds = groupedUtterances.reduce(0.0) { $0 + max(0, $1.1.end - $1.1.start) }
            return ParsedMeetingCapture.Speaker(
                id: speakerId,
                name: displayName,
                persistentSpeakerId: metadata?.persistentSpeakerId,
                confidence: metadata?.confidence,
                wordCount: wordCount,
                speakingSeconds: (speakingSeconds * 10).rounded() / 10
            )
        }

        let date = document.values["date"] ?? "1970-01-01"
        let time = document.values["time"] ?? "00:00:00"
        return ParsedMeetingCapture(
            datetime: "\(date)T\(time)",
            durationSeconds: parseDurationSeconds(document.values["duration"]),
            droppedSegments: Int(document.values["dropped_segments"] ?? "") ?? 0,
            sttEngine: document.values["transcription_engine"] ?? "unknown",
            diarizationEngine: document.values["diarization_engine"] ?? "unknown",
            speakers: speakers,
            utterances: utterances
        )
    }

    // MARK: - Dictation days

    public static func parseDictationDay(from content: String, markdownURL url: URL) -> ParsedDictationDayCapture? {
        guard let document = parseFrontmatter(from: content) else { return nil }

        let entries = parseDictationEntries(from: document.body)
        let fallbackDate = url.deletingPathExtension().lastPathComponent
            .replacingOccurrences(of: "Dictations_", with: "")

        return ParsedDictationDayCapture(
            captureType: document.values["capture_type"] ?? "dictation_day",
            date: document.values["date"] ?? fallbackDate,
            markdownFilename: url.lastPathComponent,
            entryCount: entries.count,
            wordCount: entries.reduce(0) { $0 + $1.wordCount },
            entries: entries
        )
    }

    // MARK: - Frontmatter speakers

    private static func parseFrontmatterSpeakers(from content: String) -> [ParsedFrontmatterSpeaker] {
        guard content.hasPrefix("---\n"),
              let endRange = content.range(
                of: "\n---\n",
                range: content.index(content.startIndex, offsetBy: 4)..<content.endIndex
              ) else {
            return []
        }

        let frontmatter = String(content[content.index(content.startIndex, offsetBy: 4)..<endRange.lowerBound])
        let speakerLines: [String]
        if frontmatter.hasPrefix("speakers:\n") {
            speakerLines = String(frontmatter.dropFirst("speakers:\n".count)).components(separatedBy: "\n")
        } else if let sectionRange = frontmatter.range(of: "\nspeakers:\n") {
            speakerLines = String(frontmatter[sectionRange.upperBound...]).components(separatedBy: "\n")
        } else {
            return []
        }

        var speakers: [ParsedFrontmatterSpeaker] = []
        var currentId: String?
        var currentChannel: String?
        var currentName: String?
        var currentPersistentSpeakerId: String?
        var currentConfidence: String?

        func flush() {
            if let currentId, let currentName {
                speakers.append(ParsedFrontmatterSpeaker(
                    rawId: currentId,
                    channel: currentChannel,
                    name: currentName,
                    persistentSpeakerId: currentPersistentSpeakerId,
                    confidence: currentConfidence
                ))
            }
            currentId = nil
            currentChannel = nil
            currentName = nil
            currentPersistentSpeakerId = nil
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
            } else if trimmed.hasPrefix("channel:") {
                currentChannel = trimmed
                    .replacingOccurrences(of: "channel:", with: "")
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                    .trimmingCharacters(in: CharacterSet(charactersIn: "\""))
                    .lowercased()
            } else if trimmed.hasPrefix("name:") {
                currentName = trimmed
                    .replacingOccurrences(of: "name:", with: "")
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                    .trimmingCharacters(in: CharacterSet(charactersIn: "\""))
            } else if trimmed.hasPrefix("db_id:") {
                currentPersistentSpeakerId = trimmed
                    .replacingOccurrences(of: "db_id:", with: "")
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                    .trimmingCharacters(in: CharacterSet(charactersIn: "\""))
            } else if trimmed.hasPrefix("confidence:") {
                currentConfidence = trimmed
                    .replacingOccurrences(of: "confidence:", with: "")
                    .trimmingCharacters(in: .whitespacesAndNewlines)
            } else if !trimmed.isEmpty, !trimmed.hasPrefix("-"),
                      !(rawLine.first?.isWhitespace ?? false) {
                // Only a new top-level frontmatter key ends the speakers block.
                // Indented keys the parser doesn't model (channel:, source:,
                // future writer fields) belong to the current entry and are
                // skipped, not treated as terminators.
                break
            }
        }
        flush()

        return speakers
    }

    private static func uniqueSpeakerMetadataByNormalizedName(
        _ speakers: [ParsedFrontmatterSpeaker],
        channel: String,
        includeChannelless: Bool
    ) -> [String: ParsedFrontmatterSpeaker] {
        var grouped: [String: [ParsedFrontmatterSpeaker]] = [:]
        for speaker in speakers where speaker.channel == channel || (includeChannelless && speaker.channel == nil) {
            grouped[normalizeSpeakerLabel(speaker.name), default: []].append(speaker)
        }

        var unique: [String: ParsedFrontmatterSpeaker] = [:]
        for (name, matches) in grouped where matches.count == 1 {
            unique[name] = matches[0]
        }
        return unique
    }

    private static func scopedSpeakerMetadataById(
        _ speakers: [ParsedFrontmatterSpeaker]
    ) -> [String: ParsedFrontmatterSpeaker] {
        var metadata: [String: ParsedFrontmatterSpeaker] = [:]
        for speaker in speakers {
            guard let speakerId = reservedSpeakerId(for: speaker),
                  metadata[speakerId] == nil
            else { continue }
            metadata[speakerId] = speaker
        }
        return metadata
    }

    private static func reservedSpeakerId(for speaker: ParsedFrontmatterSpeaker) -> String? {
        if let metadataChannel = speaker.channel {
            guard metadataChannel == "mic" || metadataChannel == "system" else { return nil }
            return "\(metadataChannel)_\(speaker.rawId)"
        }
        return "system_\(speaker.rawId)"
    }

    // MARK: - Transcript entries

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
            return transcriptBody.components(separatedBy: "\n").compactMap(parseLegacyTranscriptLine)
        }

        return body.components(separatedBy: "\n").compactMap(parseLegacyTranscriptLine)
    }

    private static func parseLegacyTranscriptLine(_ line: String) -> ParsedTranscriptEntry? {
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        guard trimmed.hasPrefix("["),
              let timestampEnd = trimmed.firstIndex(of: "]") else { return nil }
        let timestamp = String(trimmed[trimmed.index(after: trimmed.startIndex)..<timestampEnd])
        let afterTimestamp = trimmed[trimmed.index(after: timestampEnd)...]
        guard afterTimestamp.hasPrefix(" ["),
              let sourceStart = trimmed.index(timestampEnd, offsetBy: 3, limitedBy: trimmed.endIndex) else { return nil }
        guard let labelEnd = trimmed.range(of: "] ", range: sourceStart..<trimmed.endIndex) else { return nil }
        let sourceLabel = trimmed[sourceStart..<labelEnd.lowerBound]
        guard let separator = sourceLabel.firstIndex(of: "/") else { return nil }

        let source = String(sourceLabel[..<separator])
        let label = unwrapSpeakerLabel(String(sourceLabel[sourceLabel.index(after: separator)...]))
        return ParsedTranscriptEntry(
            timestamp: timestamp,
            startSeconds: parseTimestampSeconds(timestamp),
            source: source,
            label: label,
            text: String(trimmed[labelEnd.upperBound...]).trimmingCharacters(in: .whitespacesAndNewlines)
        )
    }

    private static func parseStyledTranscriptEntry(_ chunk: String) -> ParsedTranscriptEntry? {
        let lines = chunk.components(separatedBy: "\n").filter { !$0.isEmpty }
        guard let header = lines.first else { return nil }
        let normalizedHeader = header
            .replacingOccurrences(of: "**", with: "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard let regex = try? NSRegularExpression(pattern: #"^([0-9:]+)\s+\[(.+?)\]$"#) else { return nil }
        let nsHeader = normalizedHeader as NSString
        let range = NSRange(location: 0, length: nsHeader.length)
        guard let match = regex.firstMatch(in: normalizedHeader, range: range),
              match.numberOfRanges >= 3 else { return nil }
        let timestamp = nsHeader.substring(with: match.range(at: 1))
        let sourceLabel = nsHeader.substring(with: match.range(at: 2))
        guard let separator = sourceLabel.firstIndex(of: "/") else { return nil }

        let source = String(sourceLabel[..<separator])
        let label = unwrapSpeakerLabel(String(sourceLabel[sourceLabel.index(after: separator)...]))
        return ParsedTranscriptEntry(
            timestamp: timestamp,
            startSeconds: parseTimestampSeconds(timestamp),
            source: source,
            label: label,
            text: lines.dropFirst().joined(separator: " ").trimmingCharacters(in: .whitespacesAndNewlines)
        )
    }

    // MARK: - Dictation entries

    private static func parseDictationEntries(from body: String) -> [ParsedDictationDayCapture.Entry] {
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

        return sections.compactMap { section -> ParsedDictationDayCapture.Entry? in
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
            return ParsedDictationDayCapture.Entry(
                id: entryId.isEmpty ? "dictation-\(UUID().uuidString)" : entryId,
                createdAt: createdAt.isEmpty ? "1970-01-01T00:00:00Z" : createdAt,
                title: title.isEmpty ? heading.replacingOccurrences(of: "## ", with: "") : title,
                text: text,
                sourceAppName: sourceAppName,
                sourceAppBundleId: sourceAppBundleId,
                delivery: delivery,
                wordCount: wordCount == 0 ? text.split(whereSeparator: \.isWhitespace).count : wordCount,
                characterCount: characterCount == 0 ? text.count : characterCount
            )
        }
        .sorted { $0.createdAt < $1.createdAt }
    }

    // MARK: - Shared scalar parsing

    private static func estimatedEndSeconds(for entry: ParsedTranscriptEntry, next: ParsedTranscriptEntry?) -> Double {
        if let next, next.startSeconds > entry.startSeconds {
            return next.startSeconds
        }
        let estimatedDuration = max(1.0, min(20.0, Double(entry.text.split(whereSeparator: \.isWhitespace).count) / 2.5))
        return entry.startSeconds + estimatedDuration
    }

    private static func parseDurationSeconds(_ rawDuration: String?) -> Int {
        guard let rawDuration else { return 0 }
        let rawComponents = rawDuration.split(separator: ":", omittingEmptySubsequences: false)
        let components = rawComponents.compactMap { Int($0) }
        guard components.count == rawComponents.count,
              !components.contains(where: { $0 < 0 }) else {
            return 0
        }
        switch components.count {
        case 1:
            return components[0]
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
