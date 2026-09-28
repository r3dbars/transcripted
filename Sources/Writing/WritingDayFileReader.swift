import Foundation

/// Reads one Save my writing day file (`Writing_<YYYY-MM-dd>.md`) for the
/// Writing tab's "Today" list. The same grammar CaptureKit's
/// `CaptureMarkdownParser.parseWritingDay` reads (docs/capture-format.md):
/// one `## <h:mm a> - <title>` section per entry, then `Entry ID:`,
/// `Captured:`, `Source app:`, `Bundle ID:`, `Words:`, `Characters:` and
/// `Accepted words:` lines, a blank line, and the text. A body line the
/// writer escaped as `\## ` reads back as `## `.
///
/// Foundation only, so the root fast tests compile it. It never writes.
enum WritingDayFileReader {
    struct Entry: Equatable, Identifiable, Sendable {
        let id: String
        /// `Captured:`, the entry's first keystroke. `nil` when unreadable.
        let capturedAt: Date?
        let title: String
        let text: String
        let sourceAppName: String
        let wordCount: Int
        let acceptedWordCount: Int
    }

    struct Day: Equatable, Sendable {
        /// Newest first.
        let entries: [Entry]

        var wordCount: Int { entries.reduce(0) { $0 + $1.wordCount } }

        static let empty = Day(entries: [])
    }

    /// `Writing_<YYYY-MM-dd>.md` for the day `date` falls in, in `timeZone`.
    static func fileName(for date: Date, timeZone: TimeZone = .current) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.timeZone = timeZone
        formatter.dateFormat = "yyyy-MM-dd"
        return "Writing_\(formatter.string(from: date)).md"
    }

    /// A missing or unreadable file is an empty day.
    static func read(url: URL) -> Day {
        guard let data = try? Data(contentsOf: url),
              let content = String(data: data, encoding: .utf8) else { return .empty }
        return parse(content)
    }

    static func parse(_ content: String) -> Day {
        let lines = content.replacingOccurrences(of: "\r\n", with: "\n").components(separatedBy: "\n")
        var sections: [[String]] = []
        var current: [String] = []
        var inFrontmatter = false
        for (index, line) in lines.enumerated() {
            if index == 0, line == "---" {
                inFrontmatter = true
                continue
            }
            if inFrontmatter {
                if line == "---" { inFrontmatter = false }
                continue
            }
            if line.hasPrefix("## ") {
                if !current.isEmpty { sections.append(current) }
                current = [line]
            } else if !current.isEmpty {
                current.append(line)
            }
        }
        if !current.isEmpty { sections.append(current) }

        let entries = sections.compactMap(entry(from:))
        return Day(entries: entries.sorted { newer($0, than: $1) })
    }

    private static func entry(from lines: [String]) -> Entry? {
        guard let heading = lines.first, heading.hasPrefix("## ") else { return nil }
        let headingText = String(heading.dropFirst(3))
        let title = headingText.components(separatedBy: " - ").dropFirst().joined(separator: " - ")

        var entryID = ""
        var captured = ""
        var sourceApp: String?
        var words = 0
        var acceptedWords = 0
        var bodyLines: [String] = []
        var inBody = false
        var sawMetadata = false

        func value(_ line: String, _ key: String) -> String {
            String(line.dropFirst(key.count)).trimmingCharacters(in: .whitespaces)
        }

        for line in lines.dropFirst() {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.isEmpty {
                if !inBody, sawMetadata {
                    inBody = true
                } else if inBody {
                    bodyLines.append("")
                }
                continue
            }
            if inBody {
                bodyLines.append(line.hasPrefix("\\## ") ? String(line.dropFirst()) : line)
                continue
            }
            if trimmed.hasPrefix("Entry ID:") {
                sawMetadata = true
                entryID = value(trimmed, "Entry ID:").trimmingCharacters(in: CharacterSet(charactersIn: "`"))
            } else if trimmed.hasPrefix("Captured:") {
                sawMetadata = true
                captured = value(trimmed, "Captured:")
            } else if trimmed.hasPrefix("Source app:") {
                sawMetadata = true
                sourceApp = value(trimmed, "Source app:")
            } else if trimmed.hasPrefix("Bundle ID:") || trimmed.hasPrefix("Characters:") {
                sawMetadata = true
            } else if trimmed.hasPrefix("Words:") {
                sawMetadata = true
                words = Int(value(trimmed, "Words:")) ?? 0
            } else if trimmed.hasPrefix("Accepted words:") {
                sawMetadata = true
                acceptedWords = Int(value(trimmed, "Accepted words:")) ?? 0
            } else if !sawMetadata {
                inBody = true
                bodyLines.append(line)
            }
        }

        let text = bodyLines.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
        return Entry(
            id: entryID.isEmpty ? headingText : entryID,
            capturedAt: capturedDate(captured),
            title: title.isEmpty ? headingText : title,
            text: text,
            sourceAppName: (sourceApp?.isEmpty == false ? sourceApp : nil) ?? "Unknown",
            wordCount: words > 0 ? words : text.split(whereSeparator: \.isWhitespace).count,
            acceptedWordCount: max(0, acceptedWords)
        )
    }

    /// `Captured:` is ISO 8601 UTC with milliseconds; older or hand-edited
    /// files may drop them.
    static func capturedDate(_ value: String) -> Date? {
        guard !value.isEmpty else { return nil }
        let withFraction = ISO8601DateFormatter()
        withFraction.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let date = withFraction.date(from: value) { return date }
        let plain = ISO8601DateFormatter()
        plain.formatOptions = [.withInternetDateTime]
        return plain.date(from: value)
    }

    /// Newest first; entries without a readable time go last, in file order.
    private static func newer(_ lhs: Entry, than rhs: Entry) -> Bool {
        switch (lhs.capturedAt, rhs.capturedAt) {
        case let (left?, right?): return left > right
        case (_?, nil): return true
        default: return false
        }
    }
}
