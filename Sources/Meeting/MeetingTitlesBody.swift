import Foundation
#if canImport(TranscriptedCore)
import TranscriptedCore
#endif

/// The body half of an on-device label: a `## Summary` section right before
/// the transcript, and the `# ` heading. Pure string transforms over the
/// Markdown after the frontmatter; anything they can't place is left alone.
enum MeetingTitlesBody {
    static let summaryHeading = "## Summary"
    private static let transcriptHeadings: Set<String> = ["## Transcript", "## Full Transcript"]

    /// Inserts `## Summary` before the transcript heading, or replaces an
    /// earlier model summary there (`previousSummary`). If a `## Summary`
    /// section already exists and does not match `previousSummary`, the user
    /// wrote or edited it, so leave the body untouched.
    static func settingSummary(_ summary: String, replacing previousSummary: String? = nil, in body: String) -> String {
        let originalLines = body.components(separatedBy: "\n")
        var lines = originalLines
        if let existingRange = summaryRange(in: originalLines) {
            guard let previousSummary,
                  !previousSummary.isEmpty,
                  summaryMatches(lines: originalLines, range: existingRange, expected: previousSummary) else {
                return body
            }
            lines.removeSubrange(existingRange)
        }
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

    /// The `# ` heading to write for a saved meeting: the model's `ai_title`
    /// while it still stands in for `savedTitle` and the user hasn't renamed
    /// the meeting, else `savedTitle`.
    static func headingTitle(frontmatterLines: [String], savedTitle: String) -> String {
        let values = TranscriptFrontmatter.values(from: frontmatterLines)
        guard values[MeetingTitlesKeys.titleSetByUser] != "true",
              let aiTitle = values[MeetingTitlesKeys.title].map(MeetingTitlesKeys.normalizedTitle),
              !aiTitle.isEmpty,
              let replaces = values[MeetingTitlesKeys.titleReplaces].map(MeetingTitlesKeys.normalizedTitle),
              replaces == MeetingTitlesKeys.normalizedTitle(savedTitle) else {
            return savedTitle
        }
        return aiTitle
    }

    /// The `## Summary\n\n<text>` block before the transcript, if any.
    static func summarySection(in body: String) -> String? {
        summary(in: body).map { "\(summaryHeading)\n\n\($0)" }
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
        if let expected, !summaryMatches(lines: lines, range: range, expected: expected) {
            return lines
        }
        var result = lines
        result.removeSubrange(range)
        return result
    }

    private static func summaryMatches(lines: [String], range: Range<Int>, expected: String) -> Bool {
        let text = lines[(range.lowerBound + 1)..<range.upperBound]
            .joined(separator: " ")
            .split(whereSeparator: \.isWhitespace)
            .joined(separator: " ")
        let unescaped = text.hasPrefix("\\") ? String(text.dropFirst()) : text
        let expectedLine = singleLine(expected)
        return unescaped == expectedLine || text == expectedLine
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
