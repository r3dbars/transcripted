import Foundation

/// Shared size guards for reading capture Markdown from disk.
public enum CaptureFileLimits {
    /// Maximum byte size for a capture Markdown file we will read into memory.
    /// 16 MB is far larger than normal transcript text while bounding worst-case allocation.
    public static let maxTranscriptBytes = 16 * 1024 * 1024

    /// How much of a file `looksLikeCaptureMarkdown` reads to classify it.
    /// Classification only needs the frontmatter fences, so there is no reason
    /// to pull a whole transcript into memory — the MCP index watcher calls it
    /// once per file on every reconcile tick. 64 KB is far past any real
    /// frontmatter block (the largest is a speakers list of a few hundred
    /// entries) while keeping the read cheap.
    public static let classificationPrefixBytes = 512 * 1024
}

/// Which kind of capture artifact a Markdown file is, as far as the filename
/// and flat frontmatter can tell (see `CaptureMarkdown.captureKind(of:)`).
public enum CaptureMarkdownKind: String, Sendable {
    /// `Dictations_<date>.md` day file.
    case dictationDay = "dictation_day"
    /// `Writing_<date>.md` day file, or any file with `capture_type: writing_day`.
    case writingDay = "writing_day"
    /// Any other Markdown file with YAML frontmatter. Callers apply their own
    /// meeting filters on top (summary sidecars, `meeting_summary`, ...).
    case meeting
}

/// Detection helpers for Transcripted capture Markdown artifacts (meetings,
/// dictation day files, and writing day files). Shared by TranscriptedCLI,
/// TranscriptedMCP, and TranscriptedQA.
public enum CaptureMarkdown {
    /// Filename prefix of dictation day files (`Dictations_<YYYY-MM-dd>.md`).
    public static let dictationDayFilenamePrefix = "Dictations_"
    /// Filename prefix of writing day files (`Writing_<YYYY-MM-dd>.md`).
    public static let writingDayFilenamePrefix = "Writing_"

    /// Read a capture Markdown file as UTF-8, refusing files larger than
    /// `CaptureFileLimits.maxTranscriptBytes`.
    public static func readBoundedContents(of url: URL) -> String? {
        guard let size = try? FileManager.default.attributesOfItem(atPath: url.path)[.size] as? Int,
              size <= CaptureFileLimits.maxTranscriptBytes else {
            return nil
        }
        return try? String(contentsOf: url, encoding: .utf8)
    }

    /// Whether a Markdown file looks like a Transcripted capture artifact:
    /// either a dictation or writing day file by name, or a file with YAML
    /// frontmatter.
    public static func looksLikeCaptureMarkdown(_ url: URL) -> Bool {
        captureKind(of: url) != nil
    }

    /// Classify a capture Markdown file, or nil when it isn't one.
    ///
    /// Writing day files are recognized first, by the `Writing_` prefix or by
    /// `capture_type: writing_day`, so a writing file sitting in a shared
    /// folder (the `TRANSCRIPTED_DATA_DIR` fallback) is never mistaken for a
    /// meeting. Dictation day files are still recognized by filename only,
    /// exactly as before this helper existed.
    public static func captureKind(of url: URL) -> CaptureMarkdownKind? {
        let filename = url.deletingPathExtension().lastPathComponent
        if filename.hasPrefix(writingDayFilenamePrefix) {
            return .writingDay
        }
        if filename.hasPrefix(dictationDayFilenamePrefix) {
            return .dictationDay
        }

        // Keep the oversized-file refusal, but classify from a bounded prefix
        // rather than the whole transcript: this runs once per file on every
        // MCP reconcile tick, before any mod-date staleness check can skip it.
        // The 512 KB window matches TranscriptFrontmatter's supported maximum,
        // so a valid file with a large speakers block cannot disappear here.
        guard let size = try? FileManager.default.attributesOfItem(atPath: url.path)[.size] as? Int,
              size <= CaptureFileLimits.maxTranscriptBytes,
              let head = readPrefix(of: url, maxBytes: CaptureFileLimits.classificationPrefixBytes) else {
            return nil
        }

        guard head.hasPrefix("---\n") && head.contains("\n---\n") else {
            return nil
        }

        if CaptureMarkdownParser.parseFrontmatter(from: head)?.values["capture_type"] == CaptureMarkdownKind.writingDay.rawValue {
            return .writingDay
        }
        return .meeting
    }

    /// First `maxBytes` of a file decoded as UTF-8. The prefix can cut a
    /// multi-byte scalar in half; `String(decoding:as:)` substitutes U+FFFD
    /// there instead of failing, which is harmless because every caller scans
    /// for ASCII fence markers.
    private static func readPrefix(of url: URL, maxBytes: Int) -> String? {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return nil }
        defer { try? handle.close() }
        guard let data = try? handle.read(upToCount: maxBytes) else { return nil }
        return String(decoding: data, as: UTF8.self)
    }

    /// Whether a directory directly contains at least one regular (non-symlink)
    /// capture Markdown file. The directory itself may be a symlink; it is
    /// resolved before enumeration.
    public static func directoryHasCaptureMarkdownFiles(
        _ directory: URL,
        fileManager: FileManager = .default
    ) -> Bool {
        let enumerationRoot = directory.resolvingSymlinksInPath().standardizedFileURL
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

    /// Extract the `title:` value from YAML frontmatter, if present.
    public static func extractTitle(from content: String) -> String? {
        // Minimum valid frontmatter is "---\n...\n---\n" (8+ chars). The closing
        // delimiter search must start at offset 4 (past the opening "---\n", same
        // as CaptureMarkdownParser.parseFrontmatter): from offset 3, a file
        // beginning "---\n---\n" matches at index 3 and the YAML slice below
        // becomes an inverted range, which traps.
        guard content.count >= 8, content.hasPrefix("---"),
              let endRange = content.range(
                of: "\n---\n",
                range: content.index(content.startIndex, offsetBy: 4)..<content.endIndex
              ) else { return nil }
        let yaml = String(content[content.index(content.startIndex, offsetBy: 4)..<endRange.lowerBound])
        for line in yaml.components(separatedBy: "\n") {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed == "---" { break }
            if trimmed.hasPrefix("title:") {
                let title = String(trimmed.dropFirst(6)).trimmingCharacters(in: CharacterSet(charactersIn: "\"' "))
                return title.isEmpty ? nil : title
            }
        }
        return nil
    }
}
