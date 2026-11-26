import Foundation

// Foundation-pure numbers and copy for the Stats page (stored under the
// `.today` page id). Everything here is computed from local capture files
// only: meeting dates and durations, dictation day files, and optional
// writing day files. No SwiftUI, so it runs in the fast tests.

/// One saved meeting, reduced to what Stats counts.
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

// MARK: - Stats overview

enum TodayStatsRange: String, CaseIterable, Identifiable, Sendable {
    case today
    case last7Days
    case last30Days
    case allTime

    var id: String { rawValue }

    var title: String {
        switch self {
        case .today: return "Today"
        case .last7Days: return "7 days"
        case .last30Days: return "30 days"
        case .allTime: return "All time"
        }
    }
}

/// Aggregated KPI totals for one time window.
struct TodayRangeSummary: Equatable, Sendable {
    let meetings: Int
    let meetingMinutes: Int
    let dictations: Int
    let dictationWords: Int
    let writingEntries: Int
    let writingWords: Int

    static let empty = TodayRangeSummary(
        meetings: 0,
        meetingMinutes: 0,
        dictations: 0,
        dictationWords: 0,
        writingEntries: 0,
        writingWords: 0
    )

    var totalWords: Int { dictationWords + writingWords }
    var totalCaptures: Int { meetings + dictations + writingEntries }
    var hasAnyCapture: Bool { totalCaptures > 0 || totalWords > 0 }
    var hasWriting: Bool { writingEntries > 0 || writingWords > 0 }

    /// Average meeting length in rounded minutes, or nil when there are no
    /// recorded minutes.
    var averageMeetingMinutes: Int? {
        guard meetings > 0, meetingMinutes > 0 else { return nil }
        return max(1, Int((Double(meetingMinutes) / Double(meetings)).rounded()))
    }
}

/// One column in the rolling 7-day activity bar strip.
struct TodayActivityDay: Identifiable, Equatable, Sendable {
    let day: Date
    let isToday: Bool
    let meetings: Int
    let meetingMinutes: Int
    let dictations: Int
    let dictationWords: Int
    let writingEntries: Int
    let writingWords: Int

    var id: TimeInterval { day.timeIntervalSinceReferenceDate }
    var totalCaptures: Int { meetings + dictations + writingEntries }
    var isEmpty: Bool { totalCaptures == 0 }
}

/// Consecutive active days and active-day density.
struct TodayStreakSummary: Equatable, Sendable {
    /// Active days in a row ending today, or ending yesterday when nothing has
    /// been captured yet today (so a streak stays intact in the morning).
    let currentDays: Int
    let longestDays: Int
    let activeDaysLast7: Int
    let activeDaysLast30: Int
    let totalActiveDays: Int

    static let empty = TodayStreakSummary(
        currentDays: 0,
        longestDays: 0,
        activeDaysLast7: 0,
        activeDaysLast30: 0,
        totalActiveDays: 0
    )
}

/// One stream's share in the Capture Mix breakdown.
struct TodayCaptureMixSegment: Identifiable, Equatable, Sendable {
    let kind: TodayRecentItem.Kind
    let title: String
    let count: Int
    let detail: String
    let share: Double

    var id: TodayRecentItem.Kind { kind }
    var percentage: Int { Int((share * 100).rounded()) }
}

/// Complete Stats snapshot precomputed off the main thread.
struct TodayStatsOverview: Equatable, Sendable {
    let today: TodayRangeSummary
    let last7Days: TodayRangeSummary
    let last30Days: TodayRangeSummary
    let allTime: TodayRangeSummary
    /// Rolling 7 calendar days, oldest first, last is today.
    let dailyActivity: [TodayActivityDay]
    let streak: TodayStreakSummary

    static let empty = TodayStatsOverview(
        today: .empty,
        last7Days: .empty,
        last30Days: .empty,
        allTime: .empty,
        dailyActivity: [],
        streak: .empty
    )

    var hasAnyCapture: Bool { allTime.hasAnyCapture }
    var hasWriting: Bool { allTime.hasWriting }

    func summary(for range: TodayStatsRange) -> TodayRangeSummary {
        switch range {
        case .today: return today
        case .last7Days: return last7Days
        case .last30Days: return last30Days
        case .allTime: return allTime
        }
    }

    func captureMix(for range: TodayStatsRange) -> [TodayCaptureMixSegment] {
        let summary = summary(for: range)
        return TodayStatsBuilder.captureMix(for: summary, includeWriting: hasWriting)
    }
}

enum TodayStatsBuilder {
    static let activityDayCount = 7
    static let rollingMonthDayCount = 30

    private struct MutableTotals {
        var meetings = 0
        var meetingSeconds = 0
        var dictations = 0
        var dictationWords = 0
        var writingEntries = 0
        var writingWords = 0

        func freeze() -> TodayRangeSummary {
            TodayRangeSummary(
                meetings: meetings,
                meetingMinutes: TodayStatsBuilder.minutes(fromSeconds: meetingSeconds),
                dictations: dictations,
                dictationWords: dictationWords,
                writingEntries: writingEntries,
                writingWords: writingWords
            )
        }
    }

    static func buildOverview(
        meetings: [TodayMeetingFact],
        dictationDays: [TodayDictationDayFact],
        writing: [TodayWritingFact] = [],
        now: Date,
        calendar: Calendar = .current
    ) -> TodayStatsOverview {
        let today = calendar.startOfDay(for: now)
        let sevenDayStart = calendar.date(byAdding: .day, value: -(activityDayCount - 1), to: today) ?? today
        let thirtyDayStart = calendar.date(byAdding: .day, value: -(rollingMonthDayCount - 1), to: today) ?? today

        var todayTotals = MutableTotals()
        var sevenTotals = MutableTotals()
        var thirtyTotals = MutableTotals()
        var allTotals = MutableTotals()
        var byDay: [Date: MutableTotals] = [:]
        var activeDays = Set<Date>()

        func addDay(_ day: Date, update: (inout MutableTotals) -> Void) {
            update(&allTotals)
            if day == today {
                update(&todayTotals)
            }
            if day >= sevenDayStart && day <= today {
                update(&sevenTotals)
                var bucket = byDay[day] ?? MutableTotals()
                update(&bucket)
                byDay[day] = bucket
            }
            if day >= thirtyDayStart && day <= today {
                update(&thirtyTotals)
            }
            if day <= today {
                activeDays.insert(day)
            }
        }

        for meeting in meetings {
            let day = calendar.startOfDay(for: meeting.date)
            let seconds = max(0, meeting.durationSeconds ?? 0)
            addDay(day) {
                $0.meetings += 1
                $0.meetingSeconds += seconds
            }
        }

        for fact in dictationDays where fact.entries > 0 {
            let day = calendar.startOfDay(for: fact.day)
            let words = max(0, fact.words)
            addDay(day) {
                $0.dictations += fact.entries
                $0.dictationWords += words
            }
        }

        for entry in writing {
            let day = calendar.startOfDay(for: entry.date)
            let words = max(0, entry.words)
            addDay(day) {
                $0.writingEntries += 1
                $0.writingWords += words
            }
        }

        let dailyActivity: [TodayActivityDay] = (0..<activityDayCount).reversed().compactMap { offset in
            guard let day = calendar.date(byAdding: .day, value: -offset, to: today) else { return nil }
            let totals = byDay[day] ?? MutableTotals()
            return TodayActivityDay(
                day: day,
                isToday: offset == 0,
                meetings: totals.meetings,
                meetingMinutes: minutes(fromSeconds: totals.meetingSeconds),
                dictations: totals.dictations,
                dictationWords: totals.dictationWords,
                writingEntries: totals.writingEntries,
                writingWords: totals.writingWords
            )
        }

        let streak = buildStreak(
            activeDays: activeDays,
            today: today,
            sevenDayStart: sevenDayStart,
            thirtyDayStart: thirtyDayStart,
            calendar: calendar
        )

        return TodayStatsOverview(
            today: todayTotals.freeze(),
            last7Days: sevenTotals.freeze(),
            last30Days: thirtyTotals.freeze(),
            allTime: allTotals.freeze(),
            dailyActivity: dailyActivity,
            streak: streak
        )
    }

    static func captureMix(
        for summary: TodayRangeSummary,
        includeWriting: Bool
    ) -> [TodayCaptureMixSegment] {
        let total = summary.meetings + summary.dictations + (includeWriting ? summary.writingEntries : 0)
        func share(of count: Int) -> Double {
            guard total > 0 else { return 0 }
            return Double(count) / Double(total)
        }
        var segments: [TodayCaptureMixSegment] = [
            TodayCaptureMixSegment(
                kind: .meeting,
                title: "Meetings",
                count: summary.meetings,
                detail: summary.meetingMinutes > 0
                    ? TodayCopy.duration(minutes: summary.meetingMinutes)
                    : TodayCopy.count(summary.meetings, singular: "meeting", plural: "meetings"),
                share: share(of: summary.meetings)
            ),
            TodayCaptureMixSegment(
                kind: .dictation,
                title: "Dictations",
                count: summary.dictations,
                detail: TodayCopy.words(summary.dictationWords),
                share: share(of: summary.dictations)
            ),
        ]
        if includeWriting {
            segments.append(
                TodayCaptureMixSegment(
                    kind: .writing,
                    title: "Writing",
                    count: summary.writingEntries,
                    detail: TodayCopy.words(summary.writingWords),
                    share: share(of: summary.writingEntries)
                )
            )
        }
        return segments
    }

    private static func buildStreak(
        activeDays: Set<Date>,
        today: Date,
        sevenDayStart: Date,
        thirtyDayStart: Date,
        calendar: Calendar
    ) -> TodayStreakSummary {
        guard !activeDays.isEmpty else { return .empty }

        let anchor: Date?
        if activeDays.contains(today) {
            anchor = today
        } else if let yesterday = calendar.date(byAdding: .day, value: -1, to: today),
                  activeDays.contains(yesterday) {
            anchor = yesterday
        } else {
            anchor = nil
        }

        var currentDays = 0
        if var cursor = anchor {
            while activeDays.contains(cursor) {
                currentDays += 1
                guard let previous = calendar.date(byAdding: .day, value: -1, to: cursor) else { break }
                cursor = previous
            }
        }

        let sorted = activeDays.sorted()
        var longestDays = 0
        var run = 0
        var previousDay: Date?
        for day in sorted {
            if let prev = previousDay,
               let expectedNext = calendar.date(byAdding: .day, value: 1, to: prev),
               expectedNext == day {
                run += 1
            } else {
                run = 1
            }
            if run > longestDays { longestDays = run }
            previousDay = day
        }

        let activeLast7 = activeDays.filter { $0 >= sevenDayStart && $0 <= today }.count
        let activeLast30 = activeDays.filter { $0 >= thirtyDayStart && $0 <= today }.count

        return TodayStreakSummary(
            currentDays: currentDays,
            longestDays: longestDays,
            activeDaysLast7: activeLast7,
            activeDaysLast30: activeLast30,
            totalActiveDays: activeDays.count
        )
    }

    private static func minutes(fromSeconds seconds: Int) -> Int {
        Int((Double(seconds) / 60).rounded())
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
    /// The first lines of what was said or written.
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

    // Sendable value types: no shared mutable formatter, and no ICU
    // formatter built per entry.
    private static let fractionalStyle = Date.ISO8601FormatStyle(includingFractionalSeconds: true)
    private static let plainStyle = Date.ISO8601FormatStyle()

    private static func parseDate(_ value: String) -> Date? {
        guard let parsed = (try? fractionalStyle.parse(value)) ?? (try? plainStyle.parse(value)) else { return nil }
        return Date(timeIntervalSince1970: (parsed.timeIntervalSince1970 * 1_000).rounded() / 1_000)
    }

    static func title(for text: String, maxLength: Int = 70) -> String {
        let collapsed = text.split(whereSeparator: \.isWhitespace).joined(separator: " ")
        guard !collapsed.isEmpty else { return "Writing" }
        guard collapsed.count > maxLength else { return collapsed }
        return collapsed.prefix(maxLength).trimmingCharacters(in: .whitespaces) + "\u{2026}"
    }
}

enum TodayRecentActivity {
    /// How many latest captures the snapshot keeps.
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
        let number = TodayFormatterCache.decimalString(max(0, value))
        return "\(number) \(value == 1 ? singular : plural)"
    }

    static func words(_ value: Int) -> String {
        let number = TodayFormatterCache.decimalString(max(0, value))
        return "\(number) \(value == 1 ? "word" : "words")"
    }

    /// "Thursday, September 24".
    static func dateLine(for date: Date, locale: Locale = .current, calendar: Calendar = .current) -> String {
        TodayFormatterCache.string(from: date, template: "EEEEMMMMd", locale: locale, calendar: calendar)
    }

    /// "Thu".
    static func weekdayShort(for date: Date, locale: Locale = .current, calendar: Calendar = .current) -> String {
        TodayFormatterCache.string(from: date, template: "EEE", locale: locale, calendar: calendar)
    }

    /// "24".
    static func dayNumber(for date: Date, calendar: Calendar = .current) -> String {
        "\(calendar.component(.day, from: date))"
    }

    /// Hover tooltip for one bar in the 7-day strip.
    static func dayActivityTooltip(
        _ day: TodayActivityDay,
        locale: Locale = .current,
        calendar: Calendar = .current
    ) -> String {
        let header = dateLine(for: day.day, locale: locale, calendar: calendar)
        guard !day.isEmpty else { return "\(header) \u{00B7} No captures" }
        var parts: [String] = []
        if day.meetings > 0 {
            let length = day.meetingMinutes > 0 ? " (\(duration(minutes: day.meetingMinutes)))" : ""
            parts.append(count(day.meetings, singular: "meeting", plural: "meetings") + length)
        }
        if day.dictations > 0 {
            parts.append(count(day.dictations, singular: "dictation", plural: "dictations"))
        }
        if day.writingEntries > 0 {
            parts.append(words(day.writingWords) + " written")
        }
        return "\(header) \u{00B7} \(parts.joined(separator: ", "))"
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

// MARK: - Day rollover

/// Calendar-day helpers for Stats' midnight rollover leaf.
enum TodayClockPolicy {
    static func dayKey(_ date: Date, calendar: Calendar = .current) -> Date {
        calendar.startOfDay(for: date)
    }

    static func nextMidnight(after date: Date, calendar: Calendar = .current) -> Date {
        let start = calendar.startOfDay(for: date)
        return calendar.date(byAdding: .day, value: 1, to: start) ?? start.addingTimeInterval(86_400)
    }

    /// True when the snapshot's calendar day is not the local day of `now`.
    /// A never-built snapshot (`distantPast`) always needs a refresh.
    static func needsRollover(
        storedDay: Date,
        now: Date,
        calendar: Calendar = .current
    ) -> Bool {
        !calendar.isDate(storedDay, inSameDayAs: now)
    }
}

/// Reused Foundation formatters keyed by template, locale, calendar and time zone.
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
