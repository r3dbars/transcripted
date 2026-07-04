import Foundation

func testTimelineWeeklyStatsBuilder() {
    runSuite("WeeklyStatsBuilder slices active, meeting, and dictation minutes") {
        let calendar = timelineTestCalendar()
        let weekStart = timelineDate(calendar, day: 6, hour: 4)
        let entries = [
            timelineEntry("work", "Launch polish", day: 6, startHour: 9, minutes: 120, kind: .activity, category: "Work", color: "#B984FF", app: "Xcode", calendar: calendar),
            timelineEntry("meeting", "Standup", day: 6, startHour: 12, minutes: 45, kind: .meeting, category: "Meetings", color: "#1DAE9F", app: "Zoom", calendar: calendar),
            timelineEntry("dictation", "Notes", day: 7, startHour: 10, minutes: 30, kind: .dictation, category: "Meetings", color: "#1DAE9F", app: "Transcripted", calendar: calendar),
            timelineEntry("idle", "Away", day: 7, startHour: 13, minutes: 60, kind: .idle, category: "Idle", color: "#A0AEC0", app: nil, calendar: calendar)
        ]

        let stats = WeeklyStatsBuilder.build(entries: entries, weekStart: weekStart, calendar: calendar)

        assertEqual(stats.totalActiveMinutes, 195, "idle time should not count as active")
        assertEqual(stats.meetingMinutes, 45, "meeting load should be tracked separately")
        assertEqual(stats.dictationMinutes, 30, "dictation load should be tracked separately")
        assertEqual(stats.categoryStats.map(\.category), ["Work", "Meetings"])
        assertEqual(stats.categoryStats.first?.minutes, 120)
        assertEqual(stats.topAppSites.map(\.label), ["Xcode", "Zoom", "Transcripted"])
        assertEqual(stats.dayStats[0].activeMinutes, 165)
        assertEqual(stats.dayStats[0].meetingMinutes, 45)
        assertEqual(stats.dayStats[1].activeMinutes, 30)
    }

    runSuite("WeeklyStatsBuilder uses a 4 AM logical day and clips to the week") {
        let calendar = timelineTestCalendar()
        let weekStart = timelineDate(calendar, day: 6, hour: 4)
        let early = timelineEntry("early", "Early work", day: 6, startHour: 2, minutes: 180, kind: .activity, category: "Work", color: "#B984FF", app: "Xcode", calendar: calendar)
        let late = timelineEntry("late", "Late review", day: 12, startHour: 23, minutes: 420, kind: .activity, category: "Work", color: "#B984FF", app: "Obsidian", calendar: calendar)

        let stats = WeeklyStatsBuilder.build(entries: [early, late], weekStart: weekStart, calendar: calendar)

        assertEqual(stats.totalActiveMinutes, 360, "only time inside Monday 4 AM to next Monday 4 AM should count")
        assertEqual(stats.dayStats[0].activeMinutes, 60, "pre-4 AM time clips into the first logical day")
        assertEqual(stats.dayStats[6].activeMinutes, 300, "late Sunday clips at Monday 4 AM")
    }

    runSuite("WeeklyStatsBuilder buckets privacy-safe metric volumes") {
        assertEqual(WeeklyStatsBuilder.bucket(minutes: 0), .zero)
        assertEqual(WeeklyStatsBuilder.bucket(minutes: 14), .underFifteenMinutes)
        assertEqual(WeeklyStatsBuilder.bucket(minutes: 45), .underOneHour)
        assertEqual(WeeklyStatsBuilder.bucket(minutes: 90), .oneToThreeHours)
        assertEqual(WeeklyStatsBuilder.bucket(minutes: 240), .threeToSixHours)
        assertEqual(WeeklyStatsBuilder.bucket(minutes: 500), .sixHoursPlus)
    }
}

private func timelineTestCalendar() -> Calendar {
    var calendar = Calendar(identifier: .gregorian)
    calendar.timeZone = TimeZone(secondsFromGMT: 0) ?? .current
    return calendar
}

private func timelineDate(_ calendar: Calendar, day: Int, hour: Int, minute: Int = 0) -> Date {
    calendar.date(from: DateComponents(year: 2026, month: 7, day: day, hour: hour, minute: minute)) ?? Date()
}

private func timelineEntry(
    _ id: String,
    _ title: String,
    day: Int,
    startHour: Int,
    minutes: Int,
    kind: TimelineEntryKind,
    category: String,
    color: String,
    app: String?,
    calendar: Calendar
) -> TimelineEntryRecord {
    let start = timelineDate(calendar, day: day, hour: startHour)
    let end = calendar.date(byAdding: .minute, value: minutes, to: start) ?? start
    return TimelineEntryRecord(
        id: id,
        title: title,
        start: start,
        end: end,
        kind: kind,
        category: category,
        colorHex: color,
        appSiteLabel: app
    )
}
