import Foundation

/// Detection helpers for Transcripted capture Markdown artifacts (meetings and
/// dictation day files). Shared by TranscriptedCLI and TranscriptedMCP.
public enum CaptureMarkdown {
    /// Whether a Markdown file looks like a Transcripted capture artifact:
    /// either a dictation day file by name, or a file with YAML frontmatter.
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
        // Minimum valid frontmatter is "---\n...\n---\n" (8+ chars)
        guard content.count >= 8, content.hasPrefix("---"),
              let endRange = content.range(
                of: "\n---\n",
                range: content.index(content.startIndex, offsetBy: 3)..<content.endIndex
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
