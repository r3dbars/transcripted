import Foundation

func testTodayPresentation() {
    var calendar = Calendar(identifier: .gregorian)
    calendar.timeZone = TimeZone(identifier: "America/Los_Angeles")!
    calendar.firstWeekday = 1 // Sunday
    let locale = Locale(identifier: "en_US_POSIX")

    func date(_ month: Int, _ day: Int, _ hour: Int = 10, _ minute: Int = 0) -> Date {
        calendar.date(from: DateComponents(year: 2026, month: month, day: day, hour: hour, minute: minute))!
    }
    func sep(_ day: Int, _ hour: Int = 10, _ minute: Int = 0) -> Date {
        date(9, day, hour, minute)
    }
    let now = sep(24, 15) // Thursday, Sep 24, 2026

    runSuite("TodayStatsBuilder.buildOverview - aggregates Today, 7d, 30d, and All time") {
        let overview = TodayStatsBuilder.buildOverview(
            meetings: [
                TodayMeetingFact(date: sep(24, 9), durationSeconds: 42 * 60),     // today
                TodayMeetingFact(date: sep(24, 13), durationSeconds: 28 * 60),    // today
                TodayMeetingFact(date: sep(20, 11), durationSeconds: 60 * 60),    // within 7d
                TodayMeetingFact(date: sep(18, 10), durationSeconds: nil),        // boundary of 7d (Sep 18..24)
                TodayMeetingFact(date: sep(10, 10), durationSeconds: 30 * 60),    // within 30d, outside 7d
                TodayMeetingFact(date: date(7, 1, 9), durationSeconds: 90 * 60),  // all-time only
            ],
            dictationDays: [
                TodayDictationDayFact(day: sep(24, 0), entries: 5, words: 300),
                TodayDictationDayFact(day: sep(19, 0), entries: 2, words: 40),
                TodayDictationDayFact(day: sep(5, 0), entries: 9, words: 900),    // 30d
                TodayDictationDayFact(day: date(6, 15, 0), entries: 4, words: 200), // all-time only
            ],
            writing: [
                TodayWritingFact(entryID: "w1", date: sep(24, 12), appName: "Slack", words: 80, acceptedWords: 10, text: "hi"),
                TodayWritingFact(entryID: "w2", date: sep(1, 12), appName: "Notes", words: 120, acceptedWords: 0, text: "note"),
            ],
            now: now,
            calendar: calendar
        )

        assertEqual(overview.today.meetings, 2, "two meetings today")
        assertEqual(overview.today.meetingMinutes, 70, "42 + 28 minutes today")
        assertEqual(overview.today.averageMeetingMinutes, 35, "35m average today")
        assertEqual(overview.today.dictations, 5, "five dictations today")
        assertEqual(overview.today.dictationWords, 300, "today dictated words")
        assertEqual(overview.today.writingEntries, 1, "one writing entry today")
        assertEqual(overview.today.writingWords, 80, "today writing words")
        assertEqual(overview.today.totalWords, 380, "total words combines dictated and written")

        assertEqual(overview.last7Days.meetings, 4, "7-day window spans Sep 18 through Sep 24")
        assertEqual(overview.last7Days.meetingMinutes, 130, "unknown durations count as zero")
        assertEqual(overview.last7Days.dictations, 7, "Sep 19 + Sep 24 dictations")
        assertEqual(overview.last7Days.dictationWords, 340, "7-day dictated words")
        assertEqual(overview.last7Days.writingWords, 80, "7-day writing words")

        assertEqual(overview.last30Days.meetings, 5, "30-day window includes Sep 10")
        assertEqual(overview.last30Days.meetingMinutes, 160, "30-day meeting minutes")
        assertEqual(overview.last30Days.dictations, 16, "30-day dictations")
        assertEqual(overview.last30Days.dictationWords, 1240, "30-day dictated words")
        assertEqual(overview.last30Days.writingEntries, 2, "30-day writing entries")
        assertEqual(overview.last30Days.writingWords, 200, "30-day writing words")

        assertEqual(overview.allTime.meetings, 6, "all-time includes July meeting")
        assertEqual(overview.allTime.meetingMinutes, 250, "all-time meeting minutes")
        assertEqual(overview.allTime.dictations, 20, "all-time dictations")
        assertEqual(overview.allTime.dictationWords, 1440, "all-time dictated words")
        assertEqual(overview.allTime.totalWords, 1640, "all-time total words")

        assertEqual(overview.summary(for: .today), overview.today, "summary lookup for today")
        assertEqual(overview.summary(for: .last7Days), overview.last7Days, "summary lookup for 7d")
        assertEqual(overview.summary(for: .last30Days), overview.last30Days, "summary lookup for 30d")
        assertEqual(overview.summary(for: .allTime), overview.allTime, "summary lookup for allTime")
        assertTrue(overview.hasAnyCapture, "has captures")
        assertTrue(overview.hasWriting, "has writing")
    }

    runSuite("TodayStatsBuilder.buildOverview - empty library") {
        let overview = TodayStatsBuilder.buildOverview(meetings: [], dictationDays: [], now: now, calendar: calendar)
        assertFalse(overview.hasAnyCapture, "nothing captured")
        assertFalse(overview.hasWriting, "no writing")
        assertEqual(overview.dailyActivity.count, 7, "empty library still emits 7 rolling days")
        assertTrue(overview.dailyActivity.allSatisfy(\.isEmpty), "every day is empty")
        assertTrue(overview.dailyActivity.last?.isToday == true, "last day is today")
        assertEqual(overview.streak, .empty, "empty library has zero streak")
        assertNil(overview.allTime.averageMeetingMinutes, "no average meeting length when empty")
    }

    runSuite("TodayStatsBuilder - 7-day daily activity strip") {
        let overview = TodayStatsBuilder.buildOverview(
            meetings: [
                TodayMeetingFact(date: sep(24, 9), durationSeconds: 30 * 60),
                TodayMeetingFact(date: sep(21, 14), durationSeconds: 45 * 60),
                TodayMeetingFact(date: sep(10, 12), durationSeconds: 20 * 60), // outside 7d
            ],
            dictationDays: [
                TodayDictationDayFact(day: sep(24, 0), entries: 3, words: 120),
                TodayDictationDayFact(day: sep(18, 0), entries: 1, words: 15),
            ],
            now: now,
            calendar: calendar
        )
        let days = overview.dailyActivity
        assertEqual(days.count, 7, "seven rolling days")
        assertEqual(days.first?.day, calendar.startOfDay(for: sep(18)), "starts 6 days before today")
        assertEqual(days.last?.day, calendar.startOfDay(for: sep(24)), "ends on today")
        assertTrue(days.last?.isToday == true && days.dropLast().allSatisfy { !$0.isToday }, "only the final column is today")
        assertEqual(days[0].dictations, 1, "Sep 18 has one dictation")
        assertEqual(days[3].meetings, 1, "Sep 21 has one meeting")
        assertEqual(days[3].meetingMinutes, 45, "Sep 21 meeting minutes")
        assertTrue(days[1].isEmpty && days[2].isEmpty, "quiet days are empty")
        assertEqual(days[6].totalCaptures, 4, "today has 1 meeting + 3 dictations")
        assertEqual(overview.streak.activeDaysLast7, 3, "3 active days in the last 7")

        let todayTip = TodayCopy.dayActivityTooltip(days[6], locale: locale, calendar: calendar)
        assertTrue(todayTip.contains("1 meeting (30m)"), "tooltip includes meeting duration: \(todayTip)")
        assertTrue(todayTip.contains("3 dictations"), "tooltip includes dictation count: \(todayTip)")
        let emptyTip = TodayCopy.dayActivityTooltip(days[1], locale: locale, calendar: calendar)
        assertTrue(emptyTip.hasSuffix("No captures"), "empty day tooltip says no captures: \(emptyTip)")
    }

    runSuite("TodayStatsBuilder - streak keeps yesterday grace period and finds longest run") {
        // Active Sep 23, 22, 21 (3-day current streak ending yesterday — nothing yet today)
        // Plus an older 4-day run Sep 10..13.
        let withGrace = TodayStatsBuilder.buildOverview(
            meetings: [
                TodayMeetingFact(date: sep(23, 10), durationSeconds: 600),
                TodayMeetingFact(date: sep(22, 10), durationSeconds: 600),
                TodayMeetingFact(date: sep(13, 10), durationSeconds: 600),
                TodayMeetingFact(date: sep(12, 10), durationSeconds: 600),
                TodayMeetingFact(date: sep(11, 10), durationSeconds: 600),
                TodayMeetingFact(date: sep(10, 10), durationSeconds: 600),
            ],
            dictationDays: [
                TodayDictationDayFact(day: sep(21, 0), entries: 2, words: 40),
            ],
            now: now,
            calendar: calendar
        )
        assertEqual(withGrace.streak.currentDays, 3, "streak stays alive through today when yesterday was active")
        assertEqual(withGrace.streak.longestDays, 4, "longest streak finds the earlier 4-day run")
        assertEqual(withGrace.streak.totalActiveDays, 7, "seven distinct active days")

        // If last activity was 2 days ago (Sep 22), current streak resets to 0.
        let broken = TodayStatsBuilder.buildOverview(
            meetings: [
                TodayMeetingFact(date: sep(22, 10), durationSeconds: 600),
                TodayMeetingFact(date: sep(21, 10), durationSeconds: 600),
            ],
            dictationDays: [],
            now: now,
            calendar: calendar
        )
        assertEqual(broken.streak.currentDays, 0, "a gap of two days ends the current streak")
        assertEqual(broken.streak.longestDays, 2, "longest streak still remembers the 2-day run")
    }

    runSuite("TodayStatsBuilder - capture mix omits writing when absent and splits cleanly") {
        let noWriting = TodayStatsBuilder.buildOverview(
            meetings: [TodayMeetingFact(date: sep(24, 9), durationSeconds: 30 * 60)],
            dictationDays: [TodayDictationDayFact(day: sep(24, 0), entries: 3, words: 100)],
            now: now,
            calendar: calendar
        )
        let twoSegments = noWriting.captureMix(for: .today)
        assertEqual(twoSegments.map(\.kind), [.meeting, .dictation], "writing is omitted when library has no writing")
        assertEqual(twoSegments.map(\.percentage), [25, 75], "1 meeting vs 3 dictations is 25% / 75%")

        let withWriting = TodayStatsBuilder.buildOverview(
            meetings: [TodayMeetingFact(date: sep(24, 9), durationSeconds: 30 * 60)],
            dictationDays: [TodayDictationDayFact(day: sep(24, 0), entries: 2, words: 100)],
            writing: [TodayWritingFact(entryID: "w1", date: sep(24, 11), appName: "Slack", words: 50, acceptedWords: 0, text: "hi")],
            now: now,
            calendar: calendar
        )
        let threeSegments = withWriting.captureMix(for: .today)
        assertEqual(threeSegments.map(\.kind), [.meeting, .dictation, .writing], "writing appears when present")
        assertEqual(threeSegments.map(\.percentage), [25, 50, 25], "1 / 2 / 1 is 25% / 50% / 25%")
    }

    runSuite("TodayRecentActivity - merge newest first and cap") {
        func item(_ kind: TodayRecentItem.Kind, _ id: String, _ at: Date) -> TodayRecentItem {
            TodayRecentItem(kind: kind, id: id, title: id, date: at, durationSeconds: nil, transcriptURL: nil)
        }
        let merged = TodayRecentActivity.merge(
            meetings: [item(.meeting, "m1", sep(24, 14)), item(.meeting, "m2", sep(23))],
            dictations: [item(.dictation, "d1", sep(24, 15)), item(.dictation, "d2", sep(24, 9))],
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

    runSuite("TodayCopy - durations, counts, and dates") {
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
        assertEqual(TodayCopy.dateLine(for: now, locale: locale, calendar: calendar), "Thursday, September 24", "header date")
        assertEqual(TodayCopy.rowWhen(for: sep(23, 9), now: now, locale: locale, calendar: calendar), "Yesterday", "yesterday")
        assertEqual(TodayCopy.rowWhen(for: sep(21), now: now, locale: locale, calendar: calendar), "Monday", "this past week uses the weekday")
        assertEqual(TodayCopy.rowWhen(for: sep(10), now: now, locale: locale, calendar: calendar), "Sep 10", "older uses a short date")
        assertTrue(TodayCopy.rowWhen(for: sep(24, 14, 5), now: now, locale: locale, calendar: calendar).contains("2:05"), "today uses the time")
    }

    runSuite("TodayWritingParser - day files and millisecond timestamps") {
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
    }

    runSuite("TodayClockPolicy - midnight rollover across DST") {
        assertEqual(
            TodayClockPolicy.nextMidnight(after: sep(24, 15, 30), calendar: calendar),
            sep(25, 0, 0),
            "afternoon rolls to the next local midnight"
        )
        assertFalse(
            TodayClockPolicy.needsRollover(storedDay: sep(24, 10, 1), now: sep(24, 16, 45), calendar: calendar),
            "two times of the same local day do not roll over"
        )
        assertTrue(
            TodayClockPolicy.needsRollover(storedDay: sep(24, 23, 59), now: sep(25, 0, 1), calendar: calendar),
            "midnight starts a new day"
        )
        assertTrue(
            TodayClockPolicy.needsRollover(storedDay: .distantPast, now: sep(24, 10), calendar: calendar),
            "a never-built snapshot always needs a refresh"
        )

        var la = Calendar(identifier: .gregorian)
        la.timeZone = TimeZone(identifier: "America/Los_Angeles")!
        let beforeSpring = la.date(from: DateComponents(year: 2026, month: 3, day: 8, hour: 1, minute: 30))!
        let sameSpringDay = la.date(from: DateComponents(year: 2026, month: 3, day: 8, hour: 4, minute: 0))!
        let afterSpring = TodayClockPolicy.nextMidnight(after: beforeSpring, calendar: la)
        assertEqual(la.component(.day, from: afterSpring), 9, "DST spring-forward still lands on the next calendar day")
        assertFalse(
            TodayClockPolicy.needsRollover(storedDay: beforeSpring, now: sameSpringDay, calendar: la),
            "spring-forward stays on the same calendar day"
        )
        assertTrue(
            TodayClockPolicy.needsRollover(storedDay: beforeSpring, now: afterSpring, calendar: la),
            "the next local midnight after DST still rolls over"
        )
    }
}
