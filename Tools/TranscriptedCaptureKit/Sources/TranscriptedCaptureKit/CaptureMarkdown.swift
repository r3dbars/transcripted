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

/// Detection helpers for Transcripted capture Markdown artifacts (meetings and
/// dictation day files). Shared by TranscriptedCLI and TranscriptedMCP.
public enum CaptureMarkdown {
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
    /// either a dictation day file by name, or a file with YAML frontmatter.
    public static func looksLikeCaptureMarkdown(_ url: URL) -> Bool {
        let filename = url.deletingPathExtension().lastPathComponent
        if filename.hasPrefix("Dictations_") {
            return true
        }

        // Keep the oversized-file refusal, but classify from a bounded prefix
        // rather than the whole transcript: this runs once per file on every
        // MCP reconcile tick, before any mod-date staleness check can skip it.
        // The 512 KB window matches TranscriptFrontmatter's supported maximum,
        // so a valid file with a large speakers block cannot disappear here.
        guard let size = try? FileManager.default.attributesOfItem(atPath: url.path)[.size] as? Int,
              size <= CaptureFileLimits.maxTranscriptBytes,
              let head = readPrefix(of: url, maxBytes: CaptureFileLimits.classificationPrefixBytes) else {
            return false
        }

        return head.hasPrefix("---\n") && head.contains("\n---\n")
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
