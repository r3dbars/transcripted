import Foundation

/// The body half of an on-device label: a `## Summary` section right before
/// the transcript, and the `# ` heading. Pure string transforms over the
/// Markdown after the frontmatter; anything they can't place is left alone.
enum MeetingTitlesBody {
    static let summaryHeading = "## Summary"
    private static let transcriptHeadings: Set<String> = ["## Transcript", "## Full Transcript"]

    /// Inserts `## Summary` before the transcript heading, or replaces the
    /// one already there. No transcript heading, no change.
    static func settingSummary(_ summary: String, in body: String) -> String {
        var lines = removingSummaryLines(from: body.components(separatedBy: "\n"), matching: nil)
        guard let transcriptIndex = lines.firstIndex(where: { transcriptHeadings.contains(trimmed($0)) }) else {
            return body
        }
        lines.insert(contentsOf: [summaryHeading, "", escapedLeadingMarkdown(summary), ""], at: transcriptIndex)
        return lines.joined(separator: "\n")
    }

    /// Drops the `## Summary` section before the transcript, but only when
    /// its text is `previousSummary` (what the app wrote), so a section the
    /// person wrote stays.
    static func removingSummary(_ previousSummary: String?, from body: String) -> String {
        guard let previousSummary, !previousSummary.isEmpty else { return body }
        let lines = body.components(separatedBy: "\n")
        let removed = removingSummaryLines(from: lines, matching: previousSummary)
        return removed == lines ? body : removed.joined(separator: "\n")
    }

    /// Rewrites the first `# ` heading (before the transcript) to `newTitle`
    /// when it currently reads one of `oldTitles`.
    static func replacingHeading(from oldTitles: [String], to newTitle: String?, in body: String) -> String {
        guard let newTitle = newTitle.map(singleLine), !newTitle.isEmpty else { return body }
        let candidates = Set(oldTitles.map(singleLine))
        var lines = body.components(separatedBy: "\n")
        for index in lines.indices {
            let line = trimmed(lines[index])
            if transcriptHeadings.contains(line) { break }
            guard line.hasPrefix("# ") else { continue }
            let current = singleLine(String(line.dropFirst(2)))
            guard candidates.contains(current), current != newTitle else { return body }
            lines[index] = "# \(newTitle)"
            return lines.joined(separator: "\n")
        }
        return body
    }

    /// The summary text of a body's `## Summary` section, if any (readers
    /// that should skip it, and tests).
    static func summary(in body: String) -> String? {
        let lines = body.components(separatedBy: "\n")
        guard let range = summaryRange(in: lines) else { return nil }
        let text = lines[(range.lowerBound + 1)..<range.upperBound]
            .joined(separator: "\n")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return text.isEmpty ? nil : text
    }

    // MARK: - Helpers

    /// `## Summary` up to the next `## ` heading, only before the transcript.
    private static func summaryRange(in lines: [String]) -> Range<Int>? {
        var start: Int?
        for index in lines.indices {
            let line = trimmed(lines[index])
            if let start, line.hasPrefix("## ") { return start..<index }
            if transcriptHeadings.contains(line) { return nil }
            if line == summaryHeading { start = index }
        }
        return nil
    }

    private static func removingSummaryLines(from lines: [String], matching expected: String?) -> [String] {
        guard let range = summaryRange(in: lines) else { return lines }
        if let expected {
            let text = lines[(range.lowerBound + 1)..<range.upperBound]
                .joined(separator: " ")
                .split(whereSeparator: \.isWhitespace)
                .joined(separator: " ")
            let unescaped = text.hasPrefix("\\") ? String(text.dropFirst()) : text
            guard unescaped == singleLine(expected) || text == singleLine(expected) else { return lines }
        }
        var result = lines
        result.removeSubrange(range)
        return result
    }

    /// A model summary is one plain line; keep it from reading as a heading,
    /// list item or quote.
    private static func escapedLeadingMarkdown(_ text: String) -> String {
        guard let first = text.first, "#>-*+".contains(first) else { return text }
        return "\\" + text
    }

    private static func singleLine(_ value: String) -> String {
        value.split(whereSeparator: { $0.isWhitespace || $0.isNewline }).joined(separator: " ")
    }

    private static func trimmed(_ line: String) -> String {
        line.trimmingCharacters(in: .whitespaces)
    }
}
