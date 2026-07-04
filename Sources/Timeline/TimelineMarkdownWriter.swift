import Foundation

struct TimelineMarkdownCard {
    let start: Date
    let end: Date
    let title: String
    let category: String
    let summary: String
    let details: String?
    let kind: String
    let transcriptFilename: String?
}

enum TimelineMarkdownWriter {
    static func timelineDirectory(in captureLibrary: URL) -> URL {
        captureLibrary.appendingPathComponent("timeline", isDirectory: true)
    }

    static func markdownURL(for date: String, captureLibrary: URL) -> URL {
        timelineDirectory(in: captureLibrary).appendingPathComponent("\(date).md")
    }

    static func writeDay(
        date: String,
        cards: [TimelineMarkdownCard],
        captureLibrary: URL,
        fileManager: FileManager = .default,
        calendar: Calendar = .current
    ) throws -> URL {
        let directory = timelineDirectory(in: captureLibrary)
        try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
        let outputURL = markdownURL(for: date, captureLibrary: captureLibrary)
        let markdown = markdownForDay(date: date, cards: cards, calendar: calendar)
        try markdown.write(to: outputURL, atomically: true, encoding: .utf8)
        return outputURL
    }

    static func markdownForDay(date: String, cards: [TimelineMarkdownCard], calendar: Calendar = .current) -> String {
        let ordered = cards.sorted { $0.start == $1.start ? $0.end < $1.end : $0.start < $1.start }
        let categories = Array(Set(ordered.map(\.category))).sorted()
        let activeMinutes = ordered.reduce(0) { $0 + max(0, Int($1.end.timeIntervalSince($1.start) / 60)) }

        var lines: [String] = [
            "---",
            "capture_type: timeline",
            "format_version: 1",
            "date: \(date)",
            "card_count: \(ordered.count)",
            "active_minutes: \(activeMinutes)",
            "categories:",
        ]
        lines.append(contentsOf: categories.isEmpty ? ["  []"] : categories.map { "  - \"\(escapeYAML($0))\"" })
        lines.append("---")
        lines.append("")
        lines.append("# Timeline - \(date)")
        lines.append("")

        for (index, card) in ordered.enumerated() {
            let range = "\(timeString(card.start, calendar: calendar)) - \(timeString(card.end, calendar: calendar))"
            lines.append("\(index + 1). **\(range) - \(sanitizeInline(card.title))**")
            lines.append("   _\(sanitizeInline(card.category))_")
            lines.append("   - Kind: \(sanitizeInline(card.kind))")
            lines.append("   - Summary: \(sanitizeInline(card.summary))")
            if let details = card.details?.trimmingCharacters(in: .whitespacesAndNewlines), !details.isEmpty {
                lines.append("   - Details: \(sanitizeInline(details))")
            }
            if let transcript = card.transcriptFilename?.trimmingCharacters(in: .whitespacesAndNewlines), !transcript.isEmpty {
                let stem = transcript.hasSuffix(".md") ? String(transcript.dropLast(3)) : transcript
                lines.append("   - Transcript: [transcript](../meetings/\(stem).md)")
            }
            lines.append("")
        }
        return lines.joined(separator: "\n")
    }

    private static func timeString(_ date: Date, calendar: Calendar) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.calendar = calendar
        formatter.dateFormat = "h:mm a"
        return formatter.string(from: date)
    }

    private static func sanitizeInline(_ value: String) -> String {
        value.components(separatedBy: .newlines)
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
            .joined(separator: " ")
    }

    private static func escapeYAML(_ value: String) -> String {
        value.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"")
    }
}
