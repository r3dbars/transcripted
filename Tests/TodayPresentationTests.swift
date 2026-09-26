import Foundation

func testTodayPresentation() {
    var calendar = Calendar(identifier: .gregorian)
    calendar.timeZone = TimeZone(identifier: "America/Los_Angeles")!
    calendar.firstWeekday = 1 // Sunday
    let locale = Locale(identifier: "en_US_POSIX")

    func date(_ day: Int, _ hour: Int = 10, _ minute: Int = 0) -> Date {
        // September 2026: the 20th is a Sunday, the 24th a Thursday.
        calendar.date(from: DateComponents(year: 2026, month: 9, day: day, hour: hour, minute: minute))!
    }
    let now = date(24, 15)

    runSuite("TodayStatsBuilder - today and this week counts") {
        let stats = TodayStatsBuilder.build(
            meetings: [
                TodayMeetingFact(date: date(24, 9), durationSeconds: 42 * 60),
                TodayMeetingFact(date: date(24, 13), durationSeconds: 28 * 60),
                TodayMeetingFact(date: date(22), durationSeconds: 60 * 60),
                TodayMeetingFact(date: date(19), durationSeconds: 30 * 60), // last week
                TodayMeetingFact(date: date(21), durationSeconds: nil),
            ],
            dictationDays: [
                TodayDictationDayFact(day: date(24, 0), entries: 5, words: 300),
                TodayDictationDayFact(day: date(20, 0), entries: 2, words: 40),
                TodayDictationDayFact(day: date(18, 0), entries: 9, words: 900), // last week
            ],
            now: now,
            calendar: calendar
        )
        assertEqual(stats.todayMeetings, 2, "two meetings today")
        assertEqual(stats.todayMeetingMinutes, 70, "42 + 28 minutes today")
        assertEqual(stats.todayDictations, 5, "five dictations today")
        assertEqual(stats.todayDictationWords, 300, "today's dictated words")
        assertEqual(stats.weekMeetings, 4, "this week excludes the 19th (last week)")
        assertEqual(stats.weekMeetingMinutes, 130, "unknown durations count as zero")
        assertEqual(stats.weekDictations, 7, "dictations on the 20th and 24th")
        assertEqual(stats.weekDictationWords, 340, "this week's dictated words")
        assertTrue(stats.hasAnyCapture, "has captures")
    }

    runSuite("TodayStatsBuilder - empty library") {
        let stats = TodayStatsBuilder.build(meetings: [], dictationDays: [], now: now, calendar: calendar)
        assertTrue(!stats.hasAnyCapture, "nothing captured")
        assertTrue(!TodayContextStats.empty.hasAnyCapture, "empty placeholder has nothing")
    }

    runSuite("TodayTapeBuilder - seven days of marks") {
        func item(_ kind: TodayRecentItem.Kind, _ id: String, _ at: Date, _ seconds: Int? = nil) -> TodayRecentItem {
            TodayRecentItem(kind: kind, id: id, title: id, date: at, durationSeconds: seconds, transcriptURL: nil)
        }
        let days = TodayTapeBuilder.days(
            captures: [
                item(.meeting, "sync", date(24, 9), 3 * 60 * 60),   // 9 to noon
                item(.meeting, "quick", date(24, 15), nil),          // no duration
                item(.dictation, "d-late", date(24, 21)),
                item(.dictation, "d-early", date(24, 3)),            // before 6am clamps left
                item(.dictation, "d-mon", date(21, 12)),
                item(.meeting, "old", date(10, 12), 600),            // outside the week
            ],
            now: now,
            calendar: calendar
        )
        assertEqual(days.count, 7, "seven days")
        assertEqual(days.first?.day, calendar.startOfDay(for: date(18)), "starts six days back")
        assertTrue(days.last?.isToday == true && days.dropLast().allSatisfy { !$0.isToday }, "only the last day is today")
        let today = days.last!
        assertEqual(today.meetings.map(\.id), ["sync", "quick"], "today's meetings in time order")
        assertEqual(today.dictations.map(\.id), ["d-early", "d-late"], "today's dictations in time order")
        assertEqual(today.meetings[0].start, 1.0 / 6.0, "9am is a sixth of 6am-to-midnight")
        assertEqual(today.meetings[0].end, 1.0 / 3.0, "a 3h meeting ends at noon")
        assertTrue(!today.meetings[1].isDot && today.meetings[1].end == today.meetings[1].start, "a meeting without a length is a sliver, not a dot")
        assertTrue(today.dictations[0].isDot, "dictations are dots")
        assertEqual(today.dictations[0].start, 0, "before 6am clamps to the left edge")
        assertEqual(days[3].dictations.map(\.id), ["d-mon"], "Monday's dictation lands on Monday")
        assertTrue(days[0].isEmpty, "an empty day")
        assertTrue(!days.contains { $0.meetings.contains { $0.id == "old" } }, "older captures are left out")
        assertEqual(TodayTapeBuilder.fraction(of: date(25, 0), onDayStarting: date(24, 0), calendar: calendar), 1, "midnight is the right edge")
        let hoverLine = TodayTapeBuilder.markDescription(today.meetings[0], now: now, locale: locale, calendar: calendar)
        assertTrue(hoverLine.hasPrefix("sync \u{00B7} 9:00"), "hover line leads with title and time: \(hoverLine)")
        assertTrue(hoverLine.hasSuffix("\u{00B7} 180 min"), "hover line ends with the length: \(hoverLine)")
    }

    runSuite("TodayRecentActivity - merge newest first and cap") {
        func item(_ kind: TodayRecentItem.Kind, _ id: String, _ at: Date) -> TodayRecentItem {
            TodayRecentItem(kind: kind, id: id, title: id, date: at, durationSeconds: nil, transcriptURL: nil)
        }
        let merged = TodayRecentActivity.merge(
            meetings: [item(.meeting, "m1", date(24, 14)), item(.meeting, "m2", date(23))],
            dictations: [item(.dictation, "d1", date(24, 15)), item(.dictation, "d2", date(24, 9))],
            limit: 3
        )
        assertEqual(merged.map(\.id), ["d1", "m1", "d2"], "interleaved by date and capped")
        assertEqual(TodayRecentActivity.merge(meetings: [], dictations: [], limit: -1).count, 0, "negative limit is safe")
    }

    runSuite("TodayRecentActivity - dictation titles") {
        assertEqual(
            TodayRecentActivity.dictationTitle(text: "  Reply to Sam\nabout the date ", fallback: "x"),
            "\u{201C}Reply to Sam about the date\u{201D}",
            "whitespace collapses and the text is quoted"
        )
        assertEqual(TodayRecentActivity.dictationTitle(text: "", fallback: " Note "), "Note", "falls back to the heading")
        assertEqual(TodayRecentActivity.dictationTitle(text: "", fallback: ""), "Dictation", "last-resort title")
        let long = TodayRecentActivity.dictationTitle(text: String(repeating: "a", count: 200), fallback: "", maxLength: 10)
        assertEqual(long, "\u{201C}aaaaaaaaaa\u{2026}\u{201D}", "long text is trimmed with an ellipsis")
    }

    runSuite("TodayCopy - durations and counts") {
        assertEqual(TodayCopy.duration(minutes: 0), "0m", "zero")
        assertEqual(TodayCopy.duration(minutes: 42), "42m", "minutes only")
        assertEqual(TodayCopy.duration(minutes: 60), "1h", "whole hour")
        assertEqual(TodayCopy.duration(minutes: 108), "1h 48m", "hours and minutes")
        assertEqual(TodayCopy.duration(minutes: -5), "0m", "negative clamps")
        assertNil(TodayCopy.rowDuration(seconds: nil), "unknown duration")
        assertNil(TodayCopy.rowDuration(seconds: 30), "under a minute is hidden")
        assertEqual(TodayCopy.rowDuration(seconds: 42 * 60 + 20), "42 min", "rounded minutes")
        assertEqual(TodayCopy.count(1, singular: "meeting", plural: "meetings"), "1 meeting", "singular")
        assertEqual(TodayCopy.count(3, singular: "meeting", plural: "meetings"), "3 meetings", "plural")
        assertEqual(TodayCopy.words(1), "1 word", "one word")
        assertEqual(TodayCopy.dayNumber(for: now, calendar: calendar), "24", "day number")
        assertEqual(TodayCopy.weekdayShort(for: now, locale: locale, calendar: calendar), "Thu", "short weekday")
    }

    runSuite("TodayCopy - dates") {
        assertEqual(TodayCopy.dateLine(for: now, locale: locale, calendar: calendar), "Thursday, September 24", "header date")
        assertEqual(TodayCopy.rowWhen(for: date(23, 9), now: now, locale: locale, calendar: calendar), "Yesterday", "yesterday")
        assertEqual(TodayCopy.rowWhen(for: date(21), now: now, locale: locale, calendar: calendar), "Monday", "this past week uses the weekday")
        assertEqual(TodayCopy.rowWhen(for: date(10), now: now, locale: locale, calendar: calendar), "Sep 10", "older uses a short date")
        assertTrue(TodayCopy.rowWhen(for: date(24, 14, 5), now: now, locale: locale, calendar: calendar).contains("2:05"), "today uses the time")
    }

    runSuite("TodayWritingParser - day files") {
        let file = """
        ---
        title: "Writing for September 24, 2026"
        capture_type: writing_day
        format_version: 1
        ---

        # Writing for September 24, 2026

        ## 10:42 AM - Pushing the launch to Thursday

        Entry ID: `writing-1`
        Captured: 2026-09-24T15:42:11.387Z
        Source app: Slack
        Bundle ID: `com.tinyspeck.slackmacgap`
        Words: 12
        Characters: 65
        Accepted words: 3

        Pushing the launch to Thursday so QA
        \\## can finish.

        ## 11:05 AM - Notes

        Entry ID: `writing-2`
        Captured: 2026-09-24T16:05:00Z
        Source app: Notes
        Words: 2
        Characters: 9
        Accepted words: 0

        two words
        """
        let entries = TodayWritingParser.entries(fromDayFile: file)
        assertEqual(entries.map(\.entryID), ["writing-1", "writing-2"], "both entries, in file order")
        assertEqual(entries.first?.appName, "Slack", "source app")
        assertEqual(entries.first?.words, 12, "words from the file")
        assertEqual(entries.first?.acceptedWords, 3, "accepted words")
        assertEqual(entries.first?.text, "Pushing the launch to Thursday so QA\n## can finish.", "body keeps lines and unescapes a heading")
        assertEqual(entries.last?.date, ISO8601DateFormatter().date(from: "2026-09-24T16:05:00Z"), "Captured without milliseconds")
        assertEqual(TodayWritingParser.estimatedSeconds(words: 5), 60, "at least a minute")
        assertEqual(TodayWritingParser.estimatedSeconds(words: 5_000), 3_600, "at most an hour")

        let stats = TodayStatsBuilder.build(
            meetings: [TodayMeetingFact(date: date(24, 9), durationSeconds: 42 * 60)],
            dictationDays: [],
            writing: entries.map { TodayWritingFact(entryID: $0.entryID, date: date(24, 11), appName: $0.appName, words: $0.words, acceptedWords: $0.acceptedWords, text: $0.text) },
            now: now,
            calendar: calendar
        )
        assertEqual(stats.todayWritingWords, 14, "today's written words")
        assertEqual(stats.todayWritingApps.map(\.appName), ["Slack", "Notes"], "apps by words written")
        let parts = TodayTapeBuilder.headerParts(stats).map(\.text)
        assertEqual(parts, ["1 meeting (42m)", "14 words written"], "header skips empty streams")
    }
}
