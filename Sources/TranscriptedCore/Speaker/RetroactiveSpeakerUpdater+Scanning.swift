import Foundation

// MARK: - Retroactive Speaker Updates: File Scanning & Frontmatter Parsing
//
// Extracted from RetroactiveSpeakerUpdater.swift (audit 2026-07-08 wave 2).
// Pure code motion: the library-wide file scan/pre-filter helpers and the
// YAML frontmatter speaker-row parser, used by the rename/merge scans in
// RetroactiveSpeakerUpdater.swift.

extension TranscriptSaver {

    // MARK: - Settings Rename/Merge Helpers

    /// Markdown transcripts under the capture directory, including user-created
    /// subfolders. Depth-bounded so audio bundles and deep trees stay cheap;
    /// the db_id frontmatter check still gates every write.
    static func transcriptMarkdownFiles(under directory: URL) -> [URL] {
        guard let enumerator = FileManager.default.enumerator(
            at: directory,
            includingPropertiesForKeys: [.isRegularFileKey],
            options: [.skipsHiddenFiles, .skipsPackageDescendants]
        ) else { return [] }

        var files: [URL] = []
        for case let url as URL in enumerator {
            if enumerator.level > 4 {
                enumerator.skipDescendants()
                continue
            }
            if url.pathExtension == "md" {
                files.append(url)
            }
        }
        return files.sorted { $0.path < $1.path }
    }

    /// Verdict from the cheap frontmatter pre-scan that gates retroactive rewrites.
    enum FrontmatterScanResult {
        case matched
        case notMatched
        case needsFullRead
    }

    /// Cheap pre-filter for the library-wide rename/merge scans. `db_id` lines are
    /// only ever written inside the YAML frontmatter `speakers:` block
    /// (`TranscriptFormatter.formatTranscriptMarkdown` and
    /// `writeFrontmatterSpeakerMetadata`), so reading a file only up to its closing
    /// `---` decides whether it can reference the profile at all — without loading
    /// whole transcript bodies into memory. The search is byte-level so chunk
    /// boundaries can't split UTF-8 sequences or the needle, and anything that does
    /// not look like a well-formed frontmatter block (no leading `---`, no closing
    /// `\n---\n` within the scan cap) falls back to the historical full read so no
    /// file is ever silently skipped on ambiguity.
    static func scanFrontmatter(at url: URL, for needle: String) -> FrontmatterScanResult {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return .needsFullRead }
        defer { try? handle.close() }

        let needleBytes = Data(needle.utf8)
        let openDelimiter = Data("---\n".utf8)
        let closeDelimiter = Data("\n---\n".utf8)
        let chunkSize = 64 * 1024
        let maxScanBytes = 1024 * 1024
        var buffer = Data()

        while buffer.count < maxScanBytes {
            guard let chunk = try? handle.read(upToCount: chunkSize), !chunk.isEmpty else {
                return .needsFullRead
            }
            buffer.append(chunk)

            if buffer.count >= openDelimiter.count, !buffer.starts(with: openDelimiter) {
                return .needsFullRead
            }

            // Mirrors frontmatterContentRange: the frontmatter ends at the first
            // "\n---\n" after the opening "---\n".
            if buffer.count > openDelimiter.count,
               let closeRange = buffer.range(of: closeDelimiter, in: openDelimiter.count..<buffer.count) {
                return buffer[..<closeRange.lowerBound].range(of: needleBytes) != nil
                    ? .matched
                    : .notMatched
            }
        }
        return .needsFullRead
    }

    struct FrontmatterSpeakerRow {
        var nameLineIndex: Int?
        var channel: UtteranceChannel?
        var dbId: UUID?
        var name: String?
    }

    /// Parse the `speakers:` rows out of YAML frontmatter. Tolerates rows without
    /// a channel field (older dictation-era transcripts).
    static func parseFrontmatterSpeakerRows(in lines: [String]) -> [FrontmatterSpeakerRow] {
        guard lines.first?.trimmingCharacters(in: .whitespaces) == "---" else { return [] }

        var rows: [FrontmatterSpeakerRow] = []
        var current: FrontmatterSpeakerRow?
        var inSpeakers = false
        var speakersIndent = 0

        for index in 1..<lines.count {
            let line = lines[index]
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed == "---" { break }

            if !inSpeakers {
                if trimmed == "speakers:" {
                    inSpeakers = true
                    speakersIndent = line.prefix(while: { $0 == " " }).count
                }
                continue
            }

            let indent = line.prefix(while: { $0 == " " }).count
            if !trimmed.isEmpty, indent <= speakersIndent, !trimmed.hasPrefix("-") {
                break
            }

            if trimmed.hasPrefix("- ") {
                if let row = current { rows.append(row) }
                current = FrontmatterSpeakerRow()
            }
            guard current != nil else { continue }

            if let value = extractYAMLQuotedString(from: line, prefix: "db_id: ") {
                current?.dbId = UUID(uuidString: value)
            } else if let value = extractYAMLQuotedString(from: line, prefix: "name: ") {
                current?.name = value
                current?.nameLineIndex = index
            } else if trimmed.hasPrefix("channel: ") {
                let raw = String(trimmed.dropFirst("channel: ".count)).trimmingCharacters(in: .whitespaces)
                current?.channel = UtteranceChannel(rawValue: raw)
            }
        }
        if let row = current { rows.append(row) }
        return rows
    }

    /// Parse a YAML double-quoted string value after a known key prefix.
    /// Handles backslash escape sequences (`\"`, `\\`, etc.) and returns the unescaped value.
    /// Returns nil if the prefix is not found or the closing quote is missing.
    static func extractYAMLQuotedString(from line: String, prefix: String) -> String? {
        let fullPrefix = prefix + "\""
        guard let prefixRange = line.range(of: fullPrefix) else { return nil }
        var index = prefixRange.upperBound
        var result = ""
        while index < line.endIndex {
            let c = line[index]
            index = line.index(after: index)
            if c == "\\" && index < line.endIndex {
                let next = line[index]
                index = line.index(after: index)
                switch next {
                case "\"": result.append("\"")
                case "\\": result.append("\\")
                case "n":  result.append("\n")
                case "t":  result.append("\t")
                default:
                    result.append("\\")
                    result.append(next)
                }
            } else if c == "\"" {
                return result
            } else {
                result.append(c)
            }
        }
        return nil
    }

    static func extractTranscriptId(from url: URL) -> UUID? {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return nil }
        // read(upToCount:) (error-returning) instead of the legacy readData(ofLength:),
        // which raises an uncatchable ObjC NSException on I/O failure and hard-crashes.
        let header = try? handle.read(upToCount: 2048)
        try? handle.close()
        guard let header, let text = String(data: header, encoding: .utf8) else { return nil }
        return extractTranscriptId(fromFrontmatter: text)
    }

    private static func extractTranscriptId(fromFrontmatter text: String) -> UUID? {
        for line in text.components(separatedBy: "\n") {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            guard trimmed.hasPrefix("transcript_id:") else { continue }
            let value = trimmed
                .dropFirst("transcript_id:".count)
                .trimmingCharacters(in: .whitespacesAndNewlines)
                .trimmingCharacters(in: CharacterSet(charactersIn: "\""))
            return UUID(uuidString: value)
        }
        return nil
    }
}
