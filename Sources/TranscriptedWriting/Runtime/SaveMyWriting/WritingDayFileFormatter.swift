import Foundation

/// Renders Save my writing's day files, `Writing_<YYYY-MM-dd>.md`, exactly as
/// the phase 3 contract specifies (docs/capture-format.md once documented).
/// The shape follows the dictation day files: a header written once, then one
/// appended `## <h:mm a> - <title>` section per entry. Pure: no clock, no
/// disk. Not part of Tilde.
enum WritingDayFileFormatter {
    struct Section: Equatable, Sendable {
        let entryID: String
        /// The entry's first keystroke.
        let capturedAtMilliseconds: Int64
        let sourceAppName: String
        /// Omitted from the file when empty.
        let bundleIdentifier: String
        let wordCount: Int
        let characterCount: Int
        let acceptedWordCount: Int
        /// The settled, trimmed text.
        let text: String
    }

    static let fileNamePrefix = "Writing_"
    static let fileNameExtension = ".md"

    static func fileName(forMilliseconds milliseconds: Int64, timeZone: TimeZone) -> String {
        fileNamePrefix + dayStamp(date(milliseconds), timeZone: timeZone) + fileNameExtension
    }

    /// The frontmatter and the H1, written once when the file is created.
    static func dayHeader(forMilliseconds milliseconds: Int64, timeZone: TimeZone, locale: Locale) -> String {
        let day = formatter(dateStyle: .long, timeZone: timeZone, locale: locale)
            .string(from: date(milliseconds))
        let escapedTitle = "Writing for \(day)".replacingOccurrences(of: "\"", with: "'")
        return """
        ---
        title: "\(escapedTitle)"
        date: \(dayStamp(date(milliseconds), timeZone: timeZone))
        capture_type: writing_day
        format_version: 1
        ---

        # Writing for \(day)
        """
    }

    static func section(_ section: Section, timeZone: TimeZone, locale: Locale) -> String {
        let captured = date(section.capturedAtMilliseconds)
        let headingTitle = title(
            for: section.text,
            capturedAt: captured,
            timeZone: timeZone,
            locale: locale
        ).replacingOccurrences(of: "\n", with: " ")
        let sourceApp = section.sourceAppName.replacingOccurrences(of: "\n", with: " ")
        let bundleLine = section.bundleIdentifier.isEmpty ? "" : "\nBundle ID: `\(section.bundleIdentifier)`"
        return """
        ## \(posixFormatter("h:mm a", timeZone: timeZone).string(from: captured)) - \(headingTitle)

        Entry ID: `\(section.entryID)`
        Captured: \(iso8601UTC(milliseconds: section.capturedAtMilliseconds))
        Source app: \(sourceApp)\(bundleLine)
        Words: \(section.wordCount)
        Characters: \(section.characterCount)
        Accepted words: \(section.acceptedWordCount)

        \(body(section.text))
        """
    }

    /// A new file is the header then the section; later saves append the
    /// section only, after one blank line, like dictation day files. Bytes
    /// already in the file are kept exactly.
    static func contents(appending section: String, to existing: Data?, header: String) -> Data {
        guard var data = existing, !data.isEmpty else { return Data((header + "\n\n" + section).utf8) }
        if data.suffix(2) != Data([0x0A, 0x0A]) { data.append(contentsOf: Array("\n\n".utf8)) }
        data.append(contentsOf: Array(section.utf8))
        return data
    }

    /// `writing-<yyyyMMdd>-<HHmmss>-<SSS>-<8 hex>`, local time.
    static func entryID(forMilliseconds milliseconds: Int64, hexSuffix: String, timeZone: TimeZone) -> String {
        let stamp = posixFormatter("yyyyMMdd-HHmmss", timeZone: timeZone).string(from: date(milliseconds))
        return "writing-\(stamp)-\(threeDigitMilliseconds(milliseconds))-\(hexSuffix)"
    }

    /// The first ~7 words, or `Writing <MMM d> at <h:mm a>` for very short
    /// text (the dictation rule: under 10 characters).
    static func title(for text: String, capturedAt: Date, timeZone: TimeZone, locale: Locale) -> String {
        let candidate = text
            .replacingOccurrences(of: "\n", with: " ")
            .split(whereSeparator: \.isWhitespace)
            .prefix(7)
            .joined(separator: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        if candidate.count >= 10 { return candidate }
        let fallback = DateFormatter()
        fallback.locale = locale
        fallback.timeZone = timeZone
        fallback.dateFormat = "MMM d 'at' h:mm a"
        return "Writing \(fallback.string(from: capturedAt))"
    }

    /// The body runs to the next `## ` heading, so a line of writing that
    /// starts with one (Markdown typed in a notes app) is escaped to stay text.
    private static func body(_ text: String) -> String {
        text.split(separator: "\n", omittingEmptySubsequences: false)
            .map { $0.hasPrefix("## ") ? "\\" + $0 : String($0) }
            .joined(separator: "\n")
    }

    /// ISO 8601 in UTC with exact milliseconds (never rounded through Double).
    static func iso8601UTC(milliseconds: Int64) -> String {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        let seconds = formatter.string(from: date(milliseconds))
        return String(seconds.dropLast()) + "." + threeDigitMilliseconds(milliseconds) + "Z"
    }

    private static func date(_ milliseconds: Int64) -> Date {
        Date(timeIntervalSince1970: TimeInterval(wholeSeconds(milliseconds)))
    }

    private static func wholeSeconds(_ milliseconds: Int64) -> Int64 {
        milliseconds >= 0 ? milliseconds / 1_000 : (milliseconds - 999) / 1_000
    }

    private static func threeDigitMilliseconds(_ milliseconds: Int64) -> String {
        let fraction = milliseconds - wholeSeconds(milliseconds) * 1_000
        return String(format: "%03d", Int(fraction))
    }

    private static func dayStamp(_ date: Date, timeZone: TimeZone) -> String {
        posixFormatter("yyyy-MM-dd", timeZone: timeZone).string(from: date)
    }

    private static func posixFormatter(_ format: String, timeZone: TimeZone) -> DateFormatter {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.timeZone = timeZone
        formatter.dateFormat = format
        return formatter
    }

    private static func formatter(
        dateStyle: DateFormatter.Style,
        timeZone: TimeZone,
        locale: Locale
    ) -> DateFormatter {
        let formatter = DateFormatter()
        formatter.locale = locale
        formatter.timeZone = timeZone
        formatter.dateStyle = dateStyle
        formatter.timeStyle = .none
        return formatter
    }
}
