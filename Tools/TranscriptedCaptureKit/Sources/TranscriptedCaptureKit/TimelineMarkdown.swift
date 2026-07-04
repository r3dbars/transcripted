import Foundation

public enum TimelineMarkdownFormat {
    public static let captureType = "timeline"
    public static let formatVersion = 1

    public struct Card: Equatable, Sendable {
        public let start: Date
        public let end: Date
        public let title: String
        public let category: String
        public let summary: String
        public let details: String?
        public let kind: String
        public let transcriptFilename: String?

        public init(
            start: Date,
            end: Date,
            title: String,
            category: String,
            summary: String,
            details: String? = nil,
            kind: String = "activity",
            transcriptFilename: String? = nil
        ) {
            self.start = start
            self.end = end
            self.title = title
            self.category = category
            self.summary = summary
            self.details = details
            self.kind = kind
            self.transcriptFilename = transcriptFilename
        }
    }

    public static func markdown(date: String, cards: [Card], calendar: Calendar = .current) -> String {
        let ordered = cards.sorted { $0.start == $1.start ? $0.end < $1.end : $0.start < $1.start }
        let categories = Array(Set(ordered.map(\.category))).sorted()
        let activeMinutes = ordered.reduce(0) { total, card in
            total + max(0, Int(card.end.timeIntervalSince(card.start) / 60))
        }

        var lines: [String] = [
            "---",
            "capture_type: timeline",
            "format_version: 1",
            "date: \(date)",
            "card_count: \(ordered.count)",
            "active_minutes: \(activeMinutes)",
            "categories:",
        ]
        if categories.isEmpty {
            lines.append("  []")
        } else {
            lines.append(contentsOf: categories.map { "  - \"\(escapeYAML($0))\"" })
        }
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
        value
            .components(separatedBy: .newlines)
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
            .joined(separator: " ")
    }

    private static func escapeYAML(_ value: String) -> String {
        value.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"")
    }
}

public struct ParsedTimelineDayCapture: Equatable, Sendable {
    public let captureType: String
    public let formatVersion: Int
    public let date: String
    public let cardCount: Int
    public let activeMinutes: Int
    public let categories: [String]
    public let markdownFilename: String
    public let cards: [ParsedTimelineCard]
}

public struct ParsedTimelineCard: Equatable, Sendable {
    public let position: Int
    public let timeRange: String
    public let title: String
    public let category: String
    public let kind: String
    public let summary: String
    public let details: String?
    public let transcriptPath: String?
}

public enum TimelineMarkdownParser {
    public static func parseTimelineDay(from content: String, markdownURL url: URL) -> ParsedTimelineDayCapture? {
        guard let frontmatter = CaptureMarkdownParser.parseFrontmatter(from: content),
              frontmatter.values["capture_type"] == TimelineMarkdownFormat.captureType,
              let date = frontmatter.values["date"] else {
            return nil
        }

        let cards = parseCards(from: content)
        return ParsedTimelineDayCapture(
            captureType: frontmatter.values["capture_type"] ?? TimelineMarkdownFormat.captureType,
            formatVersion: Int(frontmatter.values["format_version"] ?? "") ?? TimelineMarkdownFormat.formatVersion,
            date: date,
            cardCount: Int(frontmatter.values["card_count"] ?? "") ?? cards.count,
            activeMinutes: Int(frontmatter.values["active_minutes"] ?? "") ?? 0,
            categories: parseCategories(from: content),
            markdownFilename: url.lastPathComponent,
            cards: cards
        )
    }

    private static func parseCards(from content: String) -> [ParsedTimelineCard] {
        let lines = content.components(separatedBy: .newlines)
        var cards: [ParsedTimelineCard] = []
        var current: ParsedTimelineCardBuilder?

        func flush() {
            guard let builder = current, let card = builder.card() else { return }
            cards.append(card)
        }

        for line in lines {
            if let header = parseCardHeader(line) {
                flush()
                current = ParsedTimelineCardBuilder(position: header.position, timeRange: header.timeRange, title: header.title)
                continue
            }

            guard current != nil else { continue }
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.hasPrefix("_"), trimmed.hasSuffix("_"), trimmed.count > 2 {
                current?.category = String(trimmed.dropFirst().dropLast())
            } else if trimmed.hasPrefix("- Kind:") {
                current?.kind = String(trimmed.dropFirst(7)).trimmingCharacters(in: .whitespaces)
            } else if trimmed.hasPrefix("- Summary:") {
                current?.summary = String(trimmed.dropFirst(10)).trimmingCharacters(in: .whitespaces)
            } else if trimmed.hasPrefix("- Details:") {
                current?.details = String(trimmed.dropFirst(10)).trimmingCharacters(in: .whitespaces)
            } else if trimmed.hasPrefix("- Transcript:") {
                current?.transcriptPath = linkPath(in: trimmed)
            }
        }
        flush()

        return cards
    }

    private static func parseCardHeader(_ line: String) -> (position: Int, timeRange: String, title: String)? {
        let pattern = #"^(\d+)\.\s+\*\*(.+)\s+-\s+(.+?)\*\*$"#
        guard let regex = try? NSRegularExpression(pattern: pattern),
              let match = regex.firstMatch(in: line, range: NSRange(line.startIndex..., in: line)),
              match.numberOfRanges == 4,
              let positionRange = Range(match.range(at: 1), in: line),
              let timeRange = Range(match.range(at: 2), in: line),
              let titleRange = Range(match.range(at: 3), in: line),
              let position = Int(line[positionRange]) else {
            return nil
        }
        return (position, String(line[timeRange]), String(line[titleRange]))
    }

    private static func parseCategories(from content: String) -> [String] {
        guard let frontmatterEnd = content.range(of: "\n---\n", range: content.index(content.startIndex, offsetBy: min(4, content.count))..<content.endIndex) else {
            return []
        }
        let frontmatter = String(content[..<frontmatterEnd.lowerBound])
        let lines = frontmatter.components(separatedBy: .newlines)
        guard let start = lines.firstIndex(where: { $0.trimmingCharacters(in: .whitespaces) == "categories:" }) else {
            return []
        }
        var categories: [String] = []
        for line in lines.dropFirst(start + 1) {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            guard trimmed.hasPrefix("- ") else { break }
            categories.append(String(trimmed.dropFirst(2)).trimmingCharacters(in: CharacterSet(charactersIn: "\"' ")))
        }
        return categories
    }

    private static func linkPath(in line: String) -> String? {
        guard let open = line.lastIndex(of: "("), let close = line.lastIndex(of: ")"), open < close else { return nil }
        return String(line[line.index(after: open)..<close])
    }
}

private struct ParsedTimelineCardBuilder {
    let position: Int
    let timeRange: String
    let title: String
    var category = ""
    var kind = "activity"
    var summary = ""
    var details: String?
    var transcriptPath: String?

    func card() -> ParsedTimelineCard? {
        guard !summary.isEmpty else { return nil }
        return ParsedTimelineCard(
            position: position,
            timeRange: timeRange,
            title: title,
            category: category,
            kind: kind,
            summary: summary,
            details: details,
            transcriptPath: transcriptPath
        )
    }
}
