import Foundation

/// Reads the hidden pipeline metadata a `format_version: 2` meeting keeps
/// next to its Markdown: `<meetings folder>/.meta/<capture_id>.json`. The
/// restyle moved engine and diagnostic keys (`transcription_engine`,
/// `processing_time`, healthy capture defaults, raw gap events, ...) there.
/// Values come back as frontmatter-style strings (lists joined with ", ").
/// Missing, oversized, symlinked or malformed files give an empty result.
public enum CaptureMeetingMetadataSidecar {
    public static let directoryName = ".meta"
    private static let maximumBytes = 256 * 1024

    public static func url(forMeetingAt markdownURL: URL, captureID: UUID) -> URL {
        markdownURL.deletingLastPathComponent()
            .appendingPathComponent(directoryName, isDirectory: true)
            .appendingPathComponent("\(captureID.uuidString).json")
    }

    /// The sidecar values for the meeting whose Markdown is `content`.
    public static func values(forMeetingAt markdownURL: URL, content: String) -> [String: String] {
        guard let values = CaptureMarkdownParser.parseFrontmatter(from: content)?.values,
              let captureID = (values["capture_id"] ?? values["transcript_id"]).flatMap(UUID.init(uuidString:)) else {
            return [:]
        }
        return self.values(at: url(forMeetingAt: markdownURL, captureID: captureID))
    }

    static func values(at url: URL) -> [String: String] {
        guard let resource = try? url.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey]),
              resource.isRegularFile == true, resource.isSymbolicLink != true,
              (resource.fileSize ?? 0) <= maximumBytes,
              let data = try? Data(contentsOf: url),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let frontmatter = object["frontmatter"] as? [String: Any] else {
            return [:]
        }
        var values: [String: String] = [:]
        for (key, value) in frontmatter {
            if let string = value as? String {
                values[key] = string
            } else if let list = value as? [String] {
                values[key] = list.joined(separator: ", ")
            }
        }
        return values
    }
}
