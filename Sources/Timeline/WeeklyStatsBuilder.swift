import Foundation

enum TimelineEntryKind: String, CaseIterable, Equatable {
    case activity
    case meeting
    case dictation
    case idle
}

struct TimelineEntryRecord: Equatable, Identifiable {
    let id: String
    let title: String
    let start: Date
    let end: Date
    let kind: TimelineEntryKind
    let category: String
    let colorHex: String
    let appSiteLabel: String?

    var durationSeconds: TimeInterval {
        max(0, end.timeIntervalSince(start))
    }
}

struct TimelineCategoryStat: Equatable, Identifiable {
    let id: String
    let category: String
    let colorHex: String
    let minutes: Int
    let percentage: Int
}

struct TimelineAppSiteStat: Equatable, Identifiable {
    let id: String
    let label: String
    let minutes: Int
}

struct TimelineDayStat: Equatable, Identifiable {
    let id: String
    let date: Date
    let activeMinutes: Int
    let meetingMinutes: Int
}

struct TimelineHeatmapCell: Equatable, Identifiable {
    let id: String
    let dayIndex: Int
    let hourIndex: Int
    let minutes: Int
}

struct TimelineFocusChip: Equatable, Identifiable {
    let id: String
    let title: String
    let minutes: Int
    let category: String
}

struct TimelineWeeklyStats: Equatable {
    let weekStart: Date
    let weekEnd: Date
    let totalActiveMinutes: Int
    let meetingMinutes: Int
    let dictationMinutes: Int
    let longestFocus: TimelineFocusChip?
    let categoryStats: [TimelineCategoryStat]
    let topAppSites: [TimelineAppSiteStat]
    let dayStats: [TimelineDayStat]
    let heatmapCells: [TimelineHeatmapCell]
}

enum TimelineMetricBucket: String, Equatable {
    case zero
    case underFifteenMinutes
    case underOneHour
    case oneToThreeHours
    case threeToSixHours
    case sixHoursPlus
}

enum WeeklyStatsBuilder {
    static let logicalDayStartHour = 4

    static func build(
        entries: [TimelineEntryRecord],
        weekStart: Date,
        calendar inputCalendar: Calendar = .current
    ) -> TimelineWeeklyStats {
        let calendar = inputCalendar
        let normalizedWeekStart = startOfLogicalDay(for: weekStart, calendar: calendar)
        let weekEnd = calendar.date(byAdding: .day, value: 7, to: normalizedWeekStart) ?? normalizedWeekStart

        var categorySeconds: [String: TimeInterval] = [:]
        var categoryColors: [String: String] = [:]
        var appSeconds: [String: TimeInterval] = [:]
        var daySeconds = Array(repeating: TimeInterval(0), count: 7)
        var dayMeetingSeconds = Array(repeating: TimeInterval(0), count: 7)
        var heatmapSeconds = Array(repeating: TimeInterval(0), count: 7 * 24)
        var meetingSeconds: TimeInterval = 0
        var dictationSeconds: TimeInterval = 0
        var longestFocus: TimelineFocusChip?

        for entry in entries where entry.end > normalizedWeekStart && entry.start < weekEnd {
            let clippedStart = max(entry.start, normalizedWeekStart)
            let clippedEnd = min(entry.end, weekEnd)
            guard clippedEnd > clippedStart else { continue }

            let clippedSeconds = clippedEnd.timeIntervalSince(clippedStart)
            if entry.kind != .idle {
                categorySeconds[entry.category, default: 0] += clippedSeconds
                categoryColors[entry.category] = entry.colorHex
                if let label = normalizedAppSiteLabel(entry.appSiteLabel) {
                    appSeconds[label, default: 0] += clippedSeconds
                }
                let minutes = roundedMinutes(clippedSeconds)
                if longestFocus == nil || minutes > (longestFocus?.minutes ?? 0) {
                    longestFocus = TimelineFocusChip(
                        id: entry.id,
                        title: entry.title,
                        minutes: minutes,
                        category: entry.category
                    )
                }
            }

            if entry.kind == .meeting {
                meetingSeconds += clippedSeconds
            }
            if entry.kind == .dictation {
                dictationSeconds += clippedSeconds
            }

            accumulate(from: clippedStart, to: clippedEnd, weekStart: normalizedWeekStart, calendar: calendar) { dayIndex, hourIndex, seconds in
                guard dayIndex >= 0 && dayIndex < 7 else { return }
                if entry.kind != .idle {
                    daySeconds[dayIndex] += seconds
                    heatmapSeconds[(dayIndex * 24) + hourIndex] += seconds
                }
                if entry.kind == .meeting {
                    dayMeetingSeconds[dayIndex] += seconds
                }
            }
        }

        let totalActiveSeconds = categorySeconds.values.reduce(0, +)
        let categoryStats = categorySeconds
            .map { category, seconds in
                TimelineCategoryStat(
                    id: category,
                    category: category,
                    colorHex: categoryColors[category] ?? "#6AADFF",
                    minutes: roundedMinutes(seconds),
                    percentage: percentage(seconds, of: totalActiveSeconds)
                )
            }
            .sorted { lhs, rhs in
                if lhs.minutes == rhs.minutes { return lhs.category < rhs.category }
                return lhs.minutes > rhs.minutes
            }

        let topAppSites = appSeconds
            .map { label, seconds in
                TimelineAppSiteStat(id: label, label: label, minutes: roundedMinutes(seconds))
            }
            .filter { $0.minutes > 0 }
            .sorted { lhs, rhs in
                if lhs.minutes == rhs.minutes { return lhs.label < rhs.label }
                return lhs.minutes > rhs.minutes
            }
            .prefix(5)
            .map { $0 }

        let dayStats = (0..<7).map { index in
            let date = calendar.date(byAdding: .day, value: index, to: normalizedWeekStart) ?? normalizedWeekStart
            return TimelineDayStat(
                id: dayIdentifier(for: date, calendar: calendar),
                date: date,
                activeMinutes: roundedMinutes(daySeconds[index]),
                meetingMinutes: roundedMinutes(dayMeetingSeconds[index])
            )
        }

        let heatmapCells = (0..<7).flatMap { dayIndex in
            (0..<24).map { hourIndex in
                TimelineHeatmapCell(
                    id: "\(dayIndex)-\(hourIndex)",
                    dayIndex: dayIndex,
                    hourIndex: hourIndex,
                    minutes: roundedMinutes(heatmapSeconds[(dayIndex * 24) + hourIndex])
                )
            }
        }

        return TimelineWeeklyStats(
            weekStart: normalizedWeekStart,
            weekEnd: weekEnd,
            totalActiveMinutes: roundedMinutes(totalActiveSeconds),
            meetingMinutes: roundedMinutes(meetingSeconds),
            dictationMinutes: roundedMinutes(dictationSeconds),
            longestFocus: longestFocus,
            categoryStats: categoryStats,
            topAppSites: topAppSites,
            dayStats: dayStats,
            heatmapCells: heatmapCells
        )
    }

    static func bucket(minutes: Int) -> TimelineMetricBucket {
        switch minutes {
        case ...0:
            return .zero
        case 1..<15:
            return .underFifteenMinutes
        case 15..<60:
            return .underOneHour
        case 60..<(3 * 60):
            return .oneToThreeHours
        case (3 * 60)..<(6 * 60):
            return .threeToSixHours
        default:
            return .sixHoursPlus
        }
    }

    static func startOfLogicalDay(for date: Date, calendar: Calendar = .current) -> Date {
        let startOfCalendarDay = calendar.startOfDay(for: date)
        let logicalStart = calendar.date(byAdding: .hour, value: logicalDayStartHour, to: startOfCalendarDay) ?? startOfCalendarDay
        if date < logicalStart {
            return calendar.date(byAdding: .day, value: -1, to: logicalStart) ?? logicalStart
        }
        return logicalStart
    }

    private static func normalizedAppSiteLabel(_ label: String?) -> String? {
        guard let trimmed = label?.trimmingCharacters(in: .whitespacesAndNewlines), !trimmed.isEmpty else {
            return nil
        }
        return trimmed
    }

    private static func accumulate(
        from start: Date,
        to end: Date,
        weekStart: Date,
        calendar: Calendar,
        consume: (Int, Int, TimeInterval) -> Void
    ) {
        var cursor = start
        while cursor < end {
            let hourStart = calendar.dateInterval(of: .hour, for: cursor)?.start ?? cursor
            let nextHour = calendar.date(byAdding: .hour, value: 1, to: hourStart) ?? end
            let segmentEnd = min(end, nextHour)
            let seconds = segmentEnd.timeIntervalSince(cursor)
            let offset = cursor.timeIntervalSince(weekStart)
            let hourOffset = max(0, Int(offset / 3_600))
            consume(hourOffset / 24, hourOffset % 24, seconds)
            cursor = segmentEnd
        }
    }

    private static func roundedMinutes(_ seconds: TimeInterval) -> Int {
        Int((seconds / 60).rounded())
    }

    private static func percentage(_ seconds: TimeInterval, of total: TimeInterval) -> Int {
        guard total > 0 else { return 0 }
        return Int(((seconds / total) * 100).rounded())
    }

    private static func dayIdentifier(for date: Date, calendar: Calendar) -> String {
        let components = calendar.dateComponents([.year, .month, .day], from: date)
        let year = components.year ?? 0
        let month = components.month ?? 0
        let day = components.day ?? 0
        return String(format: "%04d-%02d-%02d", year, month, day)
    }
}
