import Foundation

public struct CaptureMarkdownDocument {
    public let values: [String: String]
    public let body: String
}

public struct ParsedCaptureTranscriptEntry {
    public let timestamp: String
    public let startSeconds: Double
    public let source: String
    public let label: String
    public let text: String
}

public struct ParsedCaptureSpeakerMetadata {
    public let rawId: String
    public let persistentSpeakerId: String?
    public let name: String
    public let confidence: String?
}

public struct ParsedCaptureDictationEntry {
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

public enum TranscriptedCaptureMarkdownParser {
    public static func directoryHasCaptureMarkdownFiles(
        _ directory: URL,
        fileManager: FileManager,
        resolvingSymlinks: Bool = false
    ) -> Bool {
        let enumerationRoot = resolvingSymlinks
            ? directory.resolvingSymlinksInPath().standardizedFileURL
            : directory
        guard let contents = try? fileManager.contentsOfDirectory(
            at: enumerationRoot,
            includingPropertiesForKeys: [.isRegularFileKey, .isSymbolicLinkKey],
            options: [.skipsHiddenFiles]
        ) else {
            return false
        }

        return contents.contains { url in
            guard url.pathExtension == "md",
                  let values = try? url.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey])
            else {
                return false
            }
            guard values.isRegularFile == true, values.isSymbolicLink != true else {
                return false
            }
            return looksLikeCaptureMarkdown(url)
        }
    }

    public static func looksLikeCaptureMarkdown(_ url: URL) -> Bool {
        let filename = url.deletingPathExtension().lastPathComponent
        if filename.hasPrefix("Dictations_") {
            return true
        }

        guard let content = try? String(contentsOf: url, encoding: .utf8) else {
            return false
        }

        return content.hasPrefix("---\n") && content.contains("\n---\n")
    }

    public static func parseFrontmatter(from content: String) -> CaptureMarkdownDocument? {
        guard let frontmatter = splitFrontmatter(content) else { return nil }

        var values: [String: String] = [:]
        for line in frontmatter.text.components(separatedBy: "\n") {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            guard !trimmed.hasPrefix("- "),
                  let separator = trimmed.firstIndex(of: ":") else { continue }
            let key = String(trimmed[..<separator]).trimmingCharacters(in: .whitespaces)
            let value = String(trimmed[trimmed.index(after: separator)...])
                .trimmingCharacters(in: .whitespacesAndNewlines)
                .trimmingCharacters(in: CharacterSet(charactersIn: "\""))
            values[key] = value
        }

        return CaptureMarkdownDocument(values: values, body: frontmatter.body)
    }

    public static func parseSpeakerMetadata(from content: String) -> [ParsedCaptureSpeakerMetadata] {
        guard let frontmatter = splitFrontmatter(content),
              let sectionRange = frontmatter.text.range(of: "speakers:\n") else {
            return []
        }
        let speakerLines = frontmatter.text[sectionRange.upperBound...].components(separatedBy: "\n")

        var speakers: [ParsedCaptureSpeakerMetadata] = []
        var currentId: String?
        var currentPersistentId: String?
        var currentName: String?
        var currentConfidence: String?

        func cleanValue(_ raw: String, prefix: String) -> String {
            raw
                .replacingOccurrences(of: prefix, with: "")
                .trimmingCharacters(in: .whitespacesAndNewlines)
                .trimmingCharacters(in: CharacterSet(charactersIn: "\""))
        }

        func flush() {
            if let currentId, let currentName {
                speakers.append(ParsedCaptureSpeakerMetadata(
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
                currentId = cleanValue(trimmed, prefix: "- id:")
            } else if trimmed.hasPrefix("db_id:") {
                currentPersistentId = cleanValue(trimmed, prefix: "db_id:")
            } else if trimmed.hasPrefix("name:") {
                currentName = cleanValue(trimmed, prefix: "name:")
            } else if trimmed.hasPrefix("confidence:") {
                currentConfidence = cleanValue(trimmed, prefix: "confidence:")
            } else if !trimmed.hasPrefix("-"),
                      !trimmed.hasPrefix("db_id:"),
                      !trimmed.hasPrefix("name:"),
                      !trimmed.hasPrefix("confidence:"),
                      !trimmed.hasPrefix("source:"),
                      !trimmed.isEmpty {
                break
            }
        }
        flush()
        return speakers
    }

    public static func uniqueSpeakerMetadataByNormalizedName(
        _ speakers: [ParsedCaptureSpeakerMetadata]
    ) -> [String: ParsedCaptureSpeakerMetadata] {
        var grouped: [String: [ParsedCaptureSpeakerMetadata]] = [:]
        for speaker in speakers {
            grouped[normalizeSpeakerLabel(speaker.name), default: []].append(speaker)
        }

        var unique: [String: ParsedCaptureSpeakerMetadata] = [:]
        for (name, matches) in grouped where matches.count == 1 {
            unique[name] = matches[0]
        }
        return unique
    }

    public static func parseTranscriptEntries(from body: String) -> [ParsedCaptureTranscriptEntry] {
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

    public static func parseDictationEntries(from body: String) -> [ParsedCaptureDictationEntry] {
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

        return sections.compactMap(parseDictationEntry).sorted { $0.createdAt < $1.createdAt }
    }

    public static func estimatedEndSeconds(
        for entry: ParsedCaptureTranscriptEntry,
        next: ParsedCaptureTranscriptEntry?
    ) -> Double {
        if let next, next.startSeconds > entry.startSeconds {
            return next.startSeconds
        }
        let estimatedDuration = max(1.0, min(20.0, Double(entry.text.split(whereSeparator: \.isWhitespace).count) / 2.5))
        return entry.startSeconds + estimatedDuration
    }

    public static func parseDurationSeconds(_ rawDuration: String?) -> Int {
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

    public static func normalizeSpeakerLabel(_ label: String) -> String {
        unwrapSpeakerLabel(label).trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    }

    private static func parseLegacyTranscriptLine(_ line: String) -> ParsedCaptureTranscriptEntry? {
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
        return ParsedCaptureTranscriptEntry(
            timestamp: timestamp,
            startSeconds: parseTimestampSeconds(timestamp),
            source: source,
            label: label,
            text: text
        )
    }

    private static func parseStyledTranscriptEntry(_ chunk: String) -> ParsedCaptureTranscriptEntry? {
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
        return ParsedCaptureTranscriptEntry(
            timestamp: timestamp,
            startSeconds: parseTimestampSeconds(timestamp),
            source: source,
            label: label,
            text: text
        )
    }

    private static func parseDictationEntry(_ section: String) -> ParsedCaptureDictationEntry? {
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
                entryId = metadataValue(from: trimmed, prefix: "Entry ID:")
                    .trimmingCharacters(in: CharacterSet(charactersIn: "`"))
            } else if trimmed.hasPrefix("Captured:") {
                sawMetadata = true
                createdAt = metadataValue(from: trimmed, prefix: "Captured:")
            } else if trimmed.hasPrefix("Source app:") {
                sawMetadata = true
                sourceAppName = metadataValue(from: trimmed, prefix: "Source app:")
            } else if trimmed.hasPrefix("Bundle ID:") {
                sawMetadata = true
                sourceAppBundleId = metadataValue(from: trimmed, prefix: "Bundle ID:")
                    .trimmingCharacters(in: CharacterSet(charactersIn: "`"))
            } else if trimmed.hasPrefix("Delivery:") {
                sawMetadata = true
                delivery = metadataValue(from: trimmed, prefix: "Delivery:")
            } else if trimmed.hasPrefix("Words:") {
                sawMetadata = true
                wordCount = Int(metadataValue(from: trimmed, prefix: "Words:")) ?? 0
            } else if trimmed.hasPrefix("Characters:") {
                sawMetadata = true
                characterCount = Int(metadataValue(from: trimmed, prefix: "Characters:")) ?? 0
            } else if trimmed.hasPrefix("Timestamp:") {
                sawMetadata = true
                createdAt = metadataValue(from: trimmed, prefix: "Timestamp:")
            } else if !sawMetadata {
                inBody = true
                bodyLines.append(line)
            }
        }

        let text = bodyLines.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
        return ParsedCaptureDictationEntry(
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

    private static func metadataValue(from line: String, prefix: String) -> String {
        line
            .replacingOccurrences(of: prefix, with: "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
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

    private static func splitFrontmatter(_ content: String) -> (text: String, body: String)? {
        guard content.hasPrefix("---\n"),
              let endRange = content.range(
                of: "\n---\n",
                range: content.index(content.startIndex, offsetBy: 4)..<content.endIndex
              ) else {
            return nil
        }

        let frontmatterText = String(content[content.index(content.startIndex, offsetBy: 4)..<endRange.lowerBound])
        return (frontmatterText, String(content[endRange.upperBound...]))
    }
}
