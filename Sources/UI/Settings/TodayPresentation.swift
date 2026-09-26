import Foundation

// Foundation-pure numbers and copy for the Today page. Everything here is
// computed from local capture files only: meeting start/end times from the
// meeting library and per-day entry counts from the dictation day files.
// No SwiftUI, so it runs in the fast tests.

/// One saved meeting, reduced to what Today counts.
struct TodayMeetingFact: Equatable, Sendable {
    let date: Date
    /// Recorded length in seconds; nil when the transcript has no duration.
    let durationSeconds: Int?
}

/// Saved dictations on one calendar day, read from that day's file.
struct TodayDictationDayFact: Equatable, Sendable {
    let day: Date
    let entries: Int
    let words: Int
}

/// One saved writing entry, read from a `Writing_<date>.md` day file.
struct TodayWritingFact: Equatable, Sendable {
    let entryID: String
    let date: Date
    let appName: String
    let words: Int
    let acceptedWords: Int
    let text: String
}

/// Words written in one app today, for the header's per-app breakdown.
struct TodayAppWords: Equatable, Sendable {
    let appName: String
    let words: Int
}

struct TodayContextStats: Equatable, Sendable {
    let todayMeetings: Int
    let todayDictations: Int
    let todayMeetingMinutes: Int
    let todayDictationWords: Int
    let weekMeetings: Int
    let weekDictations: Int
    let weekMeetingMinutes: Int
    let weekDictationWords: Int
    var todayWritingWords: Int = 0
    var todayWritingEntries: Int = 0
    var weekWritingWords: Int = 0
    /// Most words first.
    var todayWritingApps: [TodayAppWords] = []

    static let empty = TodayContextStats(
        todayMeetings: 0,
        todayDictations: 0,
        todayMeetingMinutes: 0,
        todayDictationWords: 0,
        weekMeetings: 0,
        weekDictations: 0,
        weekMeetingMinutes: 0,
        weekDictationWords: 0
    )

    var hasAnyCapture: Bool {
        weekMeetings + weekDictations + todayMeetings + todayDictations + weekWritingWords + todayWritingWords > 0
    }
}

enum TodayStatsBuilder {
    static func build(
        meetings: [TodayMeetingFact],
        dictationDays: [TodayDictationDayFact],
        writing: [TodayWritingFact] = [],
        now: Date,
        calendar: Calendar = .current
    ) -> TodayContextStats {
        let today = calendar.startOfDay(for: now)
        let week = calendar.dateInterval(of: .weekOfYear, for: now)
            ?? DateInterval(start: today, duration: 7 * 24 * 60 * 60)

        var todayMeetings = 0
        var todayMeetingSeconds = 0
        var weekMeetings = 0
        var weekMeetingSeconds = 0
        for meeting in meetings {
            let day = calendar.startOfDay(for: meeting.date)
            let seconds = max(0, meeting.durationSeconds ?? 0)
            if day == today {
                todayMeetings += 1
                todayMeetingSeconds += seconds
            }
            if week.contains(meeting.date) {
                weekMeetings += 1
                weekMeetingSeconds += seconds
            }
        }

        var todayDictations = 0
        var todayWords = 0
        var weekDictations = 0
        var weekWords = 0
        for fact in dictationDays where fact.entries > 0 {
            let day = calendar.startOfDay(for: fact.day)
            if day == today {
                todayDictations += fact.entries
                todayWords += fact.words
            }
            if week.contains(day) {
                weekDictations += fact.entries
                weekWords += fact.words
            }
        }

        var todayWritingWords = 0
        var todayWritingEntries = 0
        var weekWritingWords = 0
        var wordsByApp: [String: Int] = [:]
        for entry in writing {
            if calendar.isDate(entry.date, inSameDayAs: now) {
                todayWritingWords += entry.words
                todayWritingEntries += 1
                wordsByApp[entry.appName, default: 0] += entry.words
            }
            if week.contains(entry.date) { weekWritingWords += entry.words }
        }
        let apps = wordsByApp
            .map { TodayAppWords(appName: $0.key, words: $0.value) }
            .sorted { $0.words != $1.words ? $0.words > $1.words : $0.appName < $1.appName }

        var stats = TodayContextStats(
            todayMeetings: todayMeetings,
            todayDictations: todayDictations,
            todayMeetingMinutes: minutes(fromSeconds: todayMeetingSeconds),
            todayDictationWords: todayWords,
            weekMeetings: weekMeetings,
            weekDictations: weekDictations,
            weekMeetingMinutes: minutes(fromSeconds: weekMeetingSeconds),
            weekDictationWords: weekWords
        )
        stats.todayWritingWords = todayWritingWords
        stats.todayWritingEntries = todayWritingEntries
        stats.weekWritingWords = weekWritingWords
        stats.todayWritingApps = apps
        return stats
    }

    private static func minutes(fromSeconds seconds: Int) -> Int {
        Int((Double(seconds) / 60).rounded())
    }
}

// MARK: - Day tape

/// One capture drawn on the day tape (the Context app's Days view): a
/// meeting is a capsule from its start to its end, a dictation is a dot.
/// Positions are fractions of the tape window, 6 AM to midnight; anything
/// earlier sits at the left edge.
struct TodayTapeMark: Identifiable, Equatable, Sendable {
    let item: TodayRecentItem
    let start: Double
    /// nil draws a dot.
    let end: Double?

    var id: String { item.id }
    var isDot: Bool { end == nil }
}

struct TodayTapeDay: Identifiable, Equatable, Sendable {
    let day: Date
    let isToday: Bool
    let meetings: [TodayTapeMark]
    let dictations: [TodayTapeMark]
    var writing: [TodayTapeMark] = []

    var id: TimeInterval { day.timeIntervalSinceReferenceDate }
    var isEmpty: Bool { meetings.isEmpty && dictations.isEmpty && writing.isEmpty }
    /// Every mark in time order, for stepping through the day.
    var allMarks: [TodayTapeMark] {
        (meetings + dictations + writing).sorted { $0.start != $1.start ? $0.start < $1.start : $0.id < $1.id }
    }
}

enum TodayTapeBuilder {
    static let windowStartHour = 6
    static let dayCount = 7

    /// Seven days, oldest first, the last one is today. Captures are the same
    /// rows the Recent list uses; a meeting's end comes from its duration.
    static func days(
        captures: [TodayRecentItem],
        now: Date,
        calendar: Calendar = .current
    ) -> [TodayTapeDay] {
        let today = calendar.startOfDay(for: now)
        return (0..<dayCount).reversed().compactMap { offset -> TodayTapeDay? in
            guard let day = calendar.date(byAdding: .day, value: -offset, to: today) else { return nil }
            let onDay = captures
                .filter { calendar.isDate($0.date, inSameDayAs: day) }
                .sorted { $0.date < $1.date }
            func mark(_ item: TodayRecentItem) -> TodayTapeMark {
                let start = fraction(of: item.date, onDayStarting: day, calendar: calendar)
                guard item.kind != .dictation, let seconds = item.durationSeconds, seconds > 0 else {
                    return TodayTapeMark(item: item, start: start, end: item.kind == .dictation ? nil : start)
                }
                let end = fraction(of: item.date.addingTimeInterval(TimeInterval(seconds)), onDayStarting: day, calendar: calendar)
                return TodayTapeMark(item: item, start: start, end: max(start, end))
            }
            return TodayTapeDay(
                day: day,
                isToday: offset == 0,
                meetings: onDay.filter { $0.kind == .meeting }.map(mark),
                dictations: onDay.filter { $0.kind == .dictation }.map(mark),
                writing: onDay.filter { $0.kind == .writing }.map(mark)
            )
        }
    }

    /// Where a moment sits on its day's tape, clamped to 0...1.
    static func fraction(of date: Date, onDayStarting day: Date, calendar: Calendar = .current) -> Double {
        let dayStart = calendar.startOfDay(for: day)
        guard let windowStart = calendar.date(byAdding: .hour, value: windowStartHour, to: dayStart),
              let windowEnd = calendar.date(byAdding: .day, value: 1, to: dayStart) else { return 0 }
        let span = windowEnd.timeIntervalSince(windowStart)
        guard span > 0 else { return 0 }
        return min(1, max(0, date.timeIntervalSince(windowStart) / span))
    }

    /// A past day's numbers for the header, from its tape marks: meeting
    /// count and length, dictation count, words written and in which apps.
    /// Only the `today…` fields are filled; the header reads those.
    static func dayStats(_ day: TodayTapeDay) -> TodayContextStats {
        let meetingSeconds = day.meetings.reduce(0) { $0 + max(0, $1.item.durationSeconds ?? 0) }
        var wordsByApp: [String: Int] = [:]
        for mark in day.writing {
            wordsByApp[mark.item.appName ?? "Unknown app", default: 0] += mark.item.words ?? 0
        }
        var stats = TodayContextStats(
            todayMeetings: day.meetings.count,
            todayDictations: day.dictations.count,
            todayMeetingMinutes: Int((Double(meetingSeconds) / 60).rounded()),
            todayDictationWords: day.dictations.reduce(0) { $0 + ($1.item.words ?? 0) },
            weekMeetings: 0,
            weekDictations: 0,
            weekMeetingMinutes: 0,
            weekDictationWords: 0
        )
        stats.todayWritingWords = wordsByApp.values.reduce(0, +)
        stats.todayWritingEntries = day.writing.count
        stats.todayWritingApps = wordsByApp
            .map { TodayAppWords(appName: $0.key, words: $0.value) }
            .sorted { $0.words != $1.words ? $0.words > $1.words : $0.appName < $1.appName }
        return stats
    }

    /// Header sentence pieces: "4 meetings (2h 10m)", "12 dictations",
    /// "1,280 words written". Only the streams with something today.
    static func headerParts(_ stats: TodayContextStats) -> [(kind: TodayRecentItem.Kind, text: String)] {
        var parts: [(TodayRecentItem.Kind, String)] = []
        if stats.todayMeetings > 0 {
            let minutes = stats.todayMeetingMinutes > 0 ? " (\(TodayCopy.duration(minutes: stats.todayMeetingMinutes)))" : ""
            parts.append((.meeting, TodayCopy.count(stats.todayMeetings, singular: "meeting", plural: "meetings") + minutes))
        }
        if stats.todayDictations > 0 {
            parts.append((.dictation, TodayCopy.count(stats.todayDictations, singular: "dictation", plural: "dictations")))
        }
        if stats.todayWritingWords > 0 {
            parts.append((.writing, TodayCopy.words(stats.todayWritingWords) + " written"))
        }
        return parts
    }

    /// Hour labels under the full tape, evenly spaced across 6 AM to midnight.
    static let hourLabels = ["6am", "9", "noon", "3", "6", "9pm"]

    /// Hover line for a mark: "Weekly sync · 2:10 PM · 42 min".
    static func markDescription(
        _ mark: TodayTapeMark,
        now: Date,
        locale: Locale = .current,
        calendar: Calendar = .current
    ) -> String {
        var parts = [mark.item.title, TodayCopy.rowWhen(for: mark.item.date, now: now, locale: locale, calendar: calendar)]
        if let duration = TodayCopy.rowDuration(seconds: mark.item.durationSeconds) {
            parts.append(duration)
        }
        return parts.joined(separator: " \u{00B7} ")
    }
}

// MARK: - Recent activity

struct TodayRecentItem: Equatable, Identifiable, Sendable {
    enum Kind: Equatable, Sendable {
        case meeting
        case dictation
        case writing
    }

    let kind: Kind
    let id: String
    let title: String
    let date: Date
    let durationSeconds: Int?
    /// Meeting transcript to reveal on the Meetings page, or a writing
    /// entry's day file; nil for dictations.
    let transcriptURL: URL?
    /// The first lines of what was said or written, for the preview card.
    var preview: String? = nil
    /// Where it was written ("Slack"); writing only.
    var appName: String? = nil
    var words: Int? = nil
    /// Words that came from accepted suggestions; writing only.
    var acceptedWords: Int? = nil
}

// MARK: - Writing day files

/// Reads Save my writing's `Writing_<YYYY-MM-dd>.md` day files (the format in
/// docs/capture-format.md). Pure text in, entries out.
enum TodayWritingParser {
    /// A writing entry's bar on the tape: the file keeps only the first
    /// keystroke, so the length is estimated from the words at a steady
    /// typing pace, at least a minute and at most an hour.
    static func estimatedSeconds(words: Int) -> Int {
        min(3_600, max(60, words * 3))
    }

    static func entries(fromDayFile contents: String) -> [TodayWritingFact] {
        var facts: [TodayWritingFact] = []
        let normalized = contents.replacingOccurrences(of: "\r\n", with: "\n")
        for chunk in normalized.components(separatedBy: "\n## ").dropFirst() {
            var lines = chunk.components(separatedBy: "\n")
            lines.removeFirst()  // the heading
            var fields: [String: String] = [:]
            var index = 0
            while index < lines.count, lines[index].trimmingCharacters(in: .whitespaces).isEmpty { index += 1 }
            while index < lines.count, !lines[index].trimmingCharacters(in: .whitespaces).isEmpty {
                let line = lines[index]
                if let colon = line.range(of: ": ") {
                    fields[String(line[..<colon.lowerBound])] = String(line[colon.upperBound...])
                        .trimmingCharacters(in: CharacterSet(charactersIn: "` "))
                }
                index += 1
            }
            guard let captured = fields["Captured"].flatMap(parseDate) else { continue }
            let body = lines[index...]
                .map { $0.hasPrefix("\\## ") ? String($0.dropFirst()) : $0 }
                .joined(separator: "\n")
                .trimmingCharacters(in: .whitespacesAndNewlines)
            facts.append(TodayWritingFact(
                entryID: fields["Entry ID"] ?? "writing-\(captured.timeIntervalSince1970)",
                date: captured,
                appName: fields["Source app"].flatMap { $0.isEmpty ? nil : $0 } ?? "Unknown app",
                words: fields["Words"].flatMap { Int($0) } ?? body.split(whereSeparator: \.isWhitespace).count,
                acceptedWords: fields["Accepted words"].flatMap { Int($0) } ?? 0,
                text: body
            ))
        }
        return facts
    }

    private static func parseDate(_ value: String) -> Date? {
        let withFraction = ISO8601DateFormatter()
        withFraction.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return withFraction.date(from: value) ?? ISO8601DateFormatter().date(from: value)
    }

    /// A writing row's title: the first line, trimmed like a dictation title
    /// but without quotes, since it's the user's own text.
    static func title(for text: String, maxLength: Int = 70) -> String {
        let collapsed = text.split(whereSeparator: \.isWhitespace).joined(separator: " ")
        guard !collapsed.isEmpty else { return "Writing" }
        guard collapsed.count > maxLength else { return collapsed }
        return collapsed.prefix(maxLength).trimmingCharacters(in: .whitespaces) + "\u{2026}"
    }
}

enum TodayRecentActivity {
    /// Rows per page of the Recent context list.
    static let pageSize = 10

    /// Newest first across every kind.
    static func merge(
        meetings: [TodayRecentItem],
        dictations: [TodayRecentItem],
        writing: [TodayRecentItem] = [],
        limit: Int = pageSize
    ) -> [TodayRecentItem] {
        Array((meetings + dictations + writing).sorted { $0.date > $1.date }.prefix(max(0, limit)))
    }

    /// One-line title for a dictation row: the spoken text, quoted and
    /// trimmed, falling back to the saved heading title.
    static func dictationTitle(text: String, fallback: String, maxLength: Int = 90) -> String {
        let collapsed = text
            .components(separatedBy: .whitespacesAndNewlines)
            .filter { !$0.isEmpty }
            .joined(separator: " ")
        guard !collapsed.isEmpty else {
            let trimmedFallback = fallback.trimmingCharacters(in: .whitespacesAndNewlines)
            return trimmedFallback.isEmpty ? "Dictation" : trimmedFallback
        }
        guard collapsed.count > maxLength else { return "\u{201C}\(collapsed)\u{201D}" }
        let cut = collapsed.prefix(maxLength).trimmingCharacters(in: .whitespaces)
        return "\u{201C}\(cut)\u{2026}\u{201D}"
    }
}

// MARK: - Copy

enum TodayCopy {
    /// "0m", "42m", "1h", "1h 48m".
    static func duration(minutes: Int) -> String {
        let clamped = max(0, minutes)
        let hours = clamped / 60
        let rest = clamped % 60
        if hours == 0 { return "\(rest)m" }
        if rest == 0 { return "\(hours)h" }
        return "\(hours)h \(rest)m"
    }

    /// Row meta for a meeting length; nil under a minute or unknown.
    static func rowDuration(seconds: Int?) -> String? {
        guard let seconds, seconds >= 60 else { return nil }
        return "\(Int((Double(seconds) / 60).rounded())) min"
    }

    static func count(_ value: Int, singular: String, plural: String) -> String {
        "\(value) \(value == 1 ? singular : plural)"
    }

    static func words(_ value: Int) -> String {
        let number = TodayFormatterCache.decimalString(max(0, value))
        return "\(number) \(value == 1 ? "word" : "words")"
    }

    /// "Thursday, September 24".
    static func dateLine(for date: Date, locale: Locale = .current, calendar: Calendar = .current) -> String {
        TodayFormatterCache.string(from: date, template: "EEEEMMMMd", locale: locale, calendar: calendar)
    }

    /// "Friday".
    static func weekdayLong(for date: Date, locale: Locale = .current, calendar: Calendar = .current) -> String {
        TodayFormatterCache.string(from: date, template: "EEEE", locale: locale, calendar: calendar)
    }

    /// "Thu".
    static func weekdayShort(for date: Date, locale: Locale = .current, calendar: Calendar = .current) -> String {
        TodayFormatterCache.string(from: date, template: "EEE", locale: locale, calendar: calendar)
    }

    /// "24".
    static func dayNumber(for date: Date, calendar: Calendar = .current) -> String {
        "\(calendar.component(.day, from: date))"
    }

    /// Time of day for today's rows, "Yesterday", or a short weekday/date.
    static func rowWhen(
        for date: Date,
        now: Date,
        locale: Locale = .current,
        calendar: Calendar = .current
    ) -> String {
        let today = calendar.startOfDay(for: now)
        let day = calendar.startOfDay(for: date)
        let template: String
        if day == today {
            template = "jmm"
        } else if let yesterday = calendar.date(byAdding: .day, value: -1, to: today), day == yesterday {
            return "Yesterday"
        } else if let daysAgo = calendar.dateComponents([.day], from: day, to: today).day, daysAgo < 7 {
            template = "EEEE"
        } else {
            template = "MMMd"
        }
        return TodayFormatterCache.string(from: date, template: template, locale: locale, calendar: calendar)
    }
}

/// Today's copy runs per Recent row and twice per tape mark on every render
/// (hover re-renders the tape), so building a DateFormatter per call adds up
/// on a busy day. Formatters are reused per template, locale, calendar and
/// time zone. Foundation formatters are safe to share for reads; the lock
/// only guards the dictionary.
enum TodayFormatterCache {
    private static let lock = NSLock()
    nonisolated(unsafe) private static var dateFormatters: [String: DateFormatter] = [:]
    nonisolated(unsafe) private static var decimalFormatters: [String: NumberFormatter] = [:]

    static func string(from date: Date, template: String, locale: Locale, calendar: Calendar) -> String {
        let key = [template, locale.identifier, "\(calendar.identifier)", calendar.timeZone.identifier]
            .joined(separator: "|")
        lock.lock()
        let formatter: DateFormatter
        if let cached = dateFormatters[key] {
            formatter = cached
        } else {
            formatter = DateFormatter()
            formatter.locale = locale
            formatter.calendar = calendar
            formatter.timeZone = calendar.timeZone
            formatter.setLocalizedDateFormatFromTemplate(template)
            dateFormatters[key] = formatter
        }
        lock.unlock()
        return formatter.string(from: date)
    }

    static func decimalString(_ value: Int, locale: Locale = .current) -> String {
        lock.lock()
        let formatter: NumberFormatter
        if let cached = decimalFormatters[locale.identifier] {
            formatter = cached
        } else {
            formatter = NumberFormatter()
            formatter.locale = locale
            formatter.numberStyle = .decimal
            decimalFormatters[locale.identifier] = formatter
        }
        lock.unlock()
        return formatter.string(from: NSNumber(value: value)) ?? "\(value)"
    }
}
