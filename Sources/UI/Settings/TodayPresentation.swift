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

struct TodayContextStats: Equatable, Sendable {
    let todayMeetings: Int
    let todayDictations: Int
    let todayMeetingMinutes: Int
    let todayDictationWords: Int
    let weekMeetings: Int
    let weekDictations: Int
    let weekMeetingMinutes: Int
    let weekDictationWords: Int

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
        weekMeetings + weekDictations + todayMeetings + todayDictations > 0
    }
}

enum TodayStatsBuilder {
    static func build(
        meetings: [TodayMeetingFact],
        dictationDays: [TodayDictationDayFact],
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

        return TodayContextStats(
            todayMeetings: todayMeetings,
            todayDictations: todayDictations,
            todayMeetingMinutes: minutes(fromSeconds: todayMeetingSeconds),
            todayDictationWords: todayWords,
            weekMeetings: weekMeetings,
            weekDictations: weekDictations,
            weekMeetingMinutes: minutes(fromSeconds: weekMeetingSeconds),
            weekDictationWords: weekWords
        )
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

    var id: TimeInterval { day.timeIntervalSinceReferenceDate }
    var isEmpty: Bool { meetings.isEmpty && dictations.isEmpty }
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
                guard item.kind == .meeting, let seconds = item.durationSeconds, seconds > 0 else {
                    return TodayTapeMark(item: item, start: start, end: item.kind == .meeting ? start : nil)
                }
                let end = fraction(of: item.date.addingTimeInterval(TimeInterval(seconds)), onDayStarting: day, calendar: calendar)
                return TodayTapeMark(item: item, start: start, end: max(start, end))
            }
            return TodayTapeDay(
                day: day,
                isToday: offset == 0,
                meetings: onDay.filter { $0.kind == .meeting }.map(mark),
                dictations: onDay.filter { $0.kind == .dictation }.map(mark)
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
    }

    let kind: Kind
    let id: String
    let title: String
    let date: Date
    let durationSeconds: Int?
    /// Meeting transcript to reveal on the Meetings page; nil for dictations.
    let transcriptURL: URL?
}

enum TodayRecentActivity {
    /// Rows per page of the Recent context list.
    static let pageSize = 10

    /// Newest first across both kinds.
    static func merge(
        meetings: [TodayRecentItem],
        dictations: [TodayRecentItem],
        limit: Int = pageSize
    ) -> [TodayRecentItem] {
        Array((meetings + dictations).sorted { $0.date > $1.date }.prefix(max(0, limit)))
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
        let formatter = NumberFormatter()
        formatter.numberStyle = .decimal
        let number = formatter.string(from: NSNumber(value: max(0, value))) ?? "\(value)"
        return "\(number) \(value == 1 ? "word" : "words")"
    }

    /// "Thursday, September 24".
    static func dateLine(for date: Date, locale: Locale = .current, calendar: Calendar = .current) -> String {
        let formatter = DateFormatter()
        formatter.locale = locale
        formatter.calendar = calendar
        formatter.timeZone = calendar.timeZone
        formatter.setLocalizedDateFormatFromTemplate("EEEEMMMMd")
        return formatter.string(from: date)
    }

    /// "Thu".
    static func weekdayShort(for date: Date, locale: Locale = .current, calendar: Calendar = .current) -> String {
        let formatter = DateFormatter()
        formatter.locale = locale
        formatter.calendar = calendar
        formatter.timeZone = calendar.timeZone
        formatter.setLocalizedDateFormatFromTemplate("EEE")
        return formatter.string(from: date)
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
        let formatter = DateFormatter()
        formatter.locale = locale
        formatter.calendar = calendar
        formatter.timeZone = calendar.timeZone
        let today = calendar.startOfDay(for: now)
        let day = calendar.startOfDay(for: date)
        if day == today {
            formatter.setLocalizedDateFormatFromTemplate("jmm")
            return formatter.string(from: date)
        }
        if let yesterday = calendar.date(byAdding: .day, value: -1, to: today), day == yesterday {
            return "Yesterday"
        }
        if let daysAgo = calendar.dateComponents([.day], from: day, to: today).day, daysAgo < 7 {
            formatter.setLocalizedDateFormatFromTemplate("EEEE")
        } else {
            formatter.setLocalizedDateFormatFromTemplate("MMMd")
        }
        return formatter.string(from: date)
    }
}
