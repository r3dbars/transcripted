import Foundation

// `format_version: 2` meeting bodies: `[MM:SS] **Speaker:** text` rows whose
// channel comes from the frontmatter `speakers:` rows, and `recorded_at`.
// See docs/capture-format.md.
extension CaptureMarkdownParser {
    /// Local "YYYY-MM-DDTHH:MM:SS": `date` + `time`, else the local part of
    /// `recorded_at` (`2026-11-26T19:58:41-06:00`).
    static func localDateTime(_ values: [String: String]) -> String {
        if let date = values["date"] {
            return "\(date)T\(values["time"] ?? "00:00:00")"
        }
        if let recordedAt = values["recorded_at"], recordedAt.count >= 19 {
            let local = String(recordedAt.prefix(19))
            let shape = #"^\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}$"#
            if local.range(of: shape, options: .regularExpression) != nil { return local }
        }
        return "1970-01-01T00:00:00"
    }

    /// Display name to `Mic` / `System` for v2 rows (`[01:43] **You:** text`):
    /// the one channel the name's `speakers:` rows use; with none or both,
    /// `You` is the mic and anyone else the call (docs/capture-format.md).
    static func dialogueChannelsByName(_ speakers: [ParsedFrontmatterSpeaker]) -> [String: Set<String>] {
        var channels: [String: Set<String>] = [:]
        for speaker in speakers {
            let channel = speaker.channel == "mic" ? "Mic" : "System"
            channels[unwrapSpeakerLabel(speaker.name), default: []].insert(channel)
        }
        return channels
    }

    /// v2: `[MM:SS] **Speaker:** text` (or `**Mic/Speaker:**` when the name
    /// alone can't tell the channel).
    static func parseDialogueTranscriptEntry(
        _ chunk: String,
        channels: [String: Set<String>]
    ) -> ParsedTranscriptEntry? {
        let lines = chunk.components(separatedBy: "\n")
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
        guard let header = lines.first, header.hasPrefix("["),
              let close = header.firstIndex(of: "]") else { return nil }
        let timestamp = String(header[header.index(after: header.startIndex)..<close])
        let parts = timestamp.split(separator: ":", omittingEmptySubsequences: false)
        guard (2...3).contains(parts.count),
              parts.allSatisfy({ !$0.isEmpty && $0.allSatisfy { $0.isASCII && $0.isNumber } }) else { return nil }
        var rest = header[header.index(after: close)...]
        guard rest.hasPrefix(" **") else { return nil }
        rest = rest.dropFirst(3)
        guard let labelEnd = rest.range(of: ":**") else { return nil }
        let label = String(rest[..<labelEnd.lowerBound])
        let text = ([String(rest[labelEnd.upperBound...])] + lines.dropFirst())
            .joined(separator: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)

        var source: String
        var name = label
        if let slash = label.firstIndex(of: "/"),
           ["Mic", "System"].contains(String(label[..<slash])) {
            source = String(label[..<slash])
            name = String(label[label.index(after: slash)...])
        } else {
            let plain = unwrapSpeakerLabel(label)
            if let known = channels[plain], known.count == 1, let only = known.first {
                source = only
            } else {
                source = plain == "You" ? "Mic" : "System"
            }
        }
        name = unwrapSpeakerLabel(name)
        guard !name.isEmpty else { return nil }
        return ParsedTranscriptEntry(
            timestamp: timestamp,
            startSeconds: parseTimestampSeconds(timestamp),
            source: source,
            label: name,
            text: text
        )
    }

}
