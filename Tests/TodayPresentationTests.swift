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
        assertEqual(overview.last7Days.meetingsWithDurationCount, 3, "only meetings with positive duration count in the average denominator")
        assertEqual(overview.last7Days.meetingMinutes, 130, "unknown durations count as zero")
        assertEqual(overview.last7Days.averageMeetingMinutes, 43, "130 / 3 = 43m (not 130 / 4 = 33m)")
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

    runSuite("TodayStatsBuilder - average meeting duration divides only by meetings with positive duration") {
        let overview = TodayStatsBuilder.buildOverview(
            meetings: [
                TodayMeetingFact(date: sep(24, 9), durationSeconds: 42 * 60),
                TodayMeetingFact(date: sep(24, 11), durationSeconds: 28 * 60),
                TodayMeetingFact(date: sep(23, 10), durationSeconds: 60 * 60),
                TodayMeetingFact(date: sep(22, 10), durationSeconds: nil),
                TodayMeetingFact(date: sep(21, 10), durationSeconds: 0),
            ],
            dictationDays: [],
            now: now,
            calendar: calendar
        )
        assertEqual(overview.last7Days.meetings, 5, "all five meetings are counted in total meetings")
        assertEqual(overview.last7Days.meetingsWithDurationCount, 3, "nil and 0-second durations are excluded from denominator")
        assertEqual(overview.last7Days.meetingMinutes, 130, "total minutes across meetings with durations")
        assertEqual(overview.last7Days.averageMeetingMinutes, 43, "130 / 3 = 43m")

        let onlyUnknown = TodayStatsBuilder.buildOverview(
            meetings: [
                TodayMeetingFact(date: sep(24, 9), durationSeconds: nil),
                TodayMeetingFact(date: sep(24, 10), durationSeconds: 0),
            ],
            dictationDays: [],
            now: now,
            calendar: calendar
        )
        assertEqual(onlyUnknown.today.meetings, 2, "meetings still count without durations")
        assertEqual(onlyUnknown.today.meetingsWithDurationCount, 0, "no meetings have positive duration")
        assertNil(onlyUnknown.today.averageMeetingDurationSeconds, "average seconds is nil when no durations were recorded")
        assertNil(onlyUnknown.today.averageMeetingMinutes, "average is nil when no durations were recorded")
        assertEqual(TodayCopy.meetingTimeSubtitle(for: onlyUnknown.today), "No durations saved", "meetings without durations show No durations saved")
        assertEqual(TodayCopy.meetingTimeSubtitle(for: .empty), "Across recorded calls", "empty range shows Across recorded calls")
    }

    runSuite("TodayStatsBuilder - average meeting duration computes from total seconds without double rounding") {
        let twoSeventyFiveSecond = TodayStatsBuilder.buildOverview(
            meetings: [
                TodayMeetingFact(date: sep(24, 9), durationSeconds: 75),
                TodayMeetingFact(date: sep(24, 11), durationSeconds: 75),
            ],
            dictationDays: [],
            now: now,
            calendar: calendar
        )
        assertEqual(twoSeventyFiveSecond.today.meetings, 2, "two 75s meetings counted")
        assertEqual(twoSeventyFiveSecond.today.meetingsWithDurationCount, 2, "both 75s meetings have positive duration")
        assertEqual(twoSeventyFiveSecond.today.meetingDurationSeconds, 150, "total seconds preserved without pre-rounding")
        assertEqual(twoSeventyFiveSecond.today.averageMeetingDurationSeconds, 75, "150 / 2 = 75s average")
        assertEqual(twoSeventyFiveSecond.today.averageMeetingMinutes, 1, "75s rounds to 1m (not 2m from pre-rounded 3m / 2)")
        assertEqual(TodayCopy.duration(seconds: 75), "1m", "75s formats as 1m")
        assertEqual(TodayCopy.meetingTimeSubtitle(for: twoSeventyFiveSecond.today), "1m avg per meeting", "two 75s meetings show 1m avg")

        let singleTwentyFiveSecond = TodayStatsBuilder.buildOverview(
            meetings: [
                TodayMeetingFact(date: sep(24, 9), durationSeconds: 25),
            ],
            dictationDays: [],
            now: now,
            calendar: calendar
        )
        assertEqual(singleTwentyFiveSecond.today.meetings, 1, "one 25s meeting counted")
        assertEqual(singleTwentyFiveSecond.today.meetingsWithDurationCount, 1, "25s meeting has positive duration")
        assertEqual(singleTwentyFiveSecond.today.meetingDurationSeconds, 25, "25s preserved")
        assertEqual(singleTwentyFiveSecond.today.averageMeetingDurationSeconds, 25, "25s average")
        assertEqual(singleTwentyFiveSecond.today.averageMeetingMinutes, 0, "sub-minute average is non-nil 0")
        assertEqual(TodayCopy.duration(seconds: 25), "< 1m", "25s formats as < 1m")
        assertEqual(TodayCopy.meetingTimeSubtitle(for: singleTwentyFiveSecond.today), "< 1m avg per meeting", "sub-minute meeting shows < 1m avg, never No durations saved")
    }

    runSuite("TodayStatsBuilder - future-dated captures are skipped across all totals and streaks") {
        let overview = TodayStatsBuilder.buildOverview(
            meetings: [
                TodayMeetingFact(date: sep(24, 9), durationSeconds: 30 * 60),
                TodayMeetingFact(date: sep(25, 10), durationSeconds: 60 * 60), // tomorrow (future)
                TodayMeetingFact(date: date(11, 1, 9), durationSeconds: 90 * 60), // far future
            ],
            dictationDays: [
                TodayDictationDayFact(day: sep(24, 0), entries: 2, words: 50),
                TodayDictationDayFact(day: sep(26, 0), entries: 5, words: 500), // future
            ],
            writing: [
                TodayWritingFact(entryID: "w-now", date: sep(24, 11), appName: "Notes", words: 25, acceptedWords: 0, text: "now"),
                TodayWritingFact(entryID: "w-future", date: sep(27, 11), appName: "Notes", words: 300, acceptedWords: 0, text: "future"),
            ],
            writingDays: [
                TodayWritingDaySummary(day: sep(28, 0), entryCount: 4, wordCount: 400, latestEntryDate: sep(28, 10)),
            ],
            now: now,
            calendar: calendar
        )

        assertEqual(overview.today.meetings, 1, "future meetings excluded from today")
        assertEqual(overview.last7Days.meetings, 1, "future meetings excluded from 7d")
        assertEqual(overview.last30Days.meetings, 1, "future meetings excluded from 30d")
        assertEqual(overview.allTime.meetings, 1, "future meetings excluded from allTime")
        assertEqual(overview.allTime.meetingMinutes, 30, "future meeting minutes excluded from allTime")
        assertEqual(overview.allTime.dictations, 2, "future dictations excluded from allTime")
        assertEqual(overview.allTime.dictationWords, 50, "future dictation words excluded from allTime")
        assertEqual(overview.allTime.writingEntries, 1, "future writing entries excluded from allTime")
        assertEqual(overview.allTime.writingWords, 25, "future writing words excluded from allTime")
        assertEqual(overview.streak.currentDays, 1, "future days do not inflate current streak")
        assertEqual(overview.streak.longestDays, 1, "future days do not inflate longest streak")
        assertEqual(overview.streak.totalActiveDays, 1, "future days do not inflate active days")
    }

    runSuite("TodayStatsBuilder - writing summaries spanning more than 7 and 30 days") {
        let dayFileContents = """
        # Writing for September 10, 2026

        ## 9:00 AM - Draft

        Entry ID: `w-1`
        Captured: 2026-09-10T14:00:00Z
        Source app: Notes
        Words: 120
        Accepted words: 20

        body text that should not be cached

        ## 11:30 AM - Follow up

        Entry ID: `w-2`
        Captured: 2026-09-10T16:30:00Z
        Source app: Slack
        Words: 80
        Accepted words: 0

        more body text
        """
        let sep10Summary = TodayWritingParser.daySummary(
            fromDayFile: dayFileContents,
            day: calendar.startOfDay(for: sep(10))
        )
        assertEqual(sep10Summary.entryCount, 2, "daySummary counts all entries in the file")
        assertEqual(sep10Summary.wordCount, 200, "daySummary sums words across entries")
        assertEqual(
            sep10Summary.latestEntryDate,
            ISO8601DateFormatter().date(from: "2026-09-10T16:30:00Z"),
            "daySummary tracks latest entry timestamp"
        )

        let overview = TodayStatsBuilder.buildOverview(
            meetings: [],
            dictationDays: [],
            writingDays: [
                TodayWritingDaySummary(day: calendar.startOfDay(for: sep(24)), entryCount: 1, wordCount: 40, latestEntryDate: sep(24, 10)),
                TodayWritingDaySummary(day: calendar.startOfDay(for: sep(19)), entryCount: 2, wordCount: 60, latestEntryDate: sep(19, 10)),
                sep10Summary, // >7d, within 30d
                TodayWritingDaySummary(day: calendar.startOfDay(for: date(7, 15)), entryCount: 3, wordCount: 500, latestEntryDate: date(7, 15, 10)), // >30d
            ],
            now: now,
            calendar: calendar
        )

        assertEqual(overview.today.writingEntries, 1, "today writing entries")
        assertEqual(overview.today.writingWords, 40, "today writing words")
        assertEqual(overview.last7Days.writingEntries, 3, "7-day writing entries")
        assertEqual(overview.last7Days.writingWords, 100, "7-day writing words")
        assertEqual(overview.last30Days.writingEntries, 5, "30-day writing entries include >7d day file")
        assertEqual(overview.last30Days.writingWords, 300, "30-day writing words include >7d day file")
        assertEqual(overview.allTime.writingEntries, 8, "all-time writing entries include >30d day file")
        assertEqual(overview.allTime.writingWords, 800, "all-time writing words include >30d day file")
        assertEqual(overview.streak.activeDaysLast7, 2, "writing days count toward 7d active days")
        assertEqual(overview.streak.activeDaysLast30, 3, "writing days count toward 30d active days")
        assertEqual(overview.streak.totalActiveDays, 4, "writing days count toward all-time active days")
    }

    runSuite("TodayStatsBuilder & TodayClockPolicy - America/Santiago 2026-09-06 DST midnight skip") {
        var santiago = Calendar(identifier: .gregorian)
        santiago.timeZone = TimeZone(identifier: "America/Santiago")!

        func scl(_ day: Int, _ hour: Int = 12, _ minute: Int = 0) -> Date {
            santiago.date(from: DateComponents(year: 2026, month: 9, day: day, hour: hour, minute: minute))!
        }

        // On 2026-09-06 in America/Santiago, midnight 00:00 is skipped and startOfDay is 01:00.
        let dstDayNow = scl(6, 15)
        let dstStart = santiago.startOfDay(for: dstDayNow)
        assertEqual(santiago.component(.hour, from: dstStart), 1, "Santiago 2026-09-06 skips 00:00 and starts at 01:00")

        // When today IS the DST day (Sep 6), subtracting days from 01:00 must still match startOfDay keys (00:00).
        let onDstDay = TodayStatsBuilder.buildOverview(
            meetings: [
                TodayMeetingFact(date: scl(6, 10), durationSeconds: 1800),
                TodayMeetingFact(date: scl(5, 10), durationSeconds: 1800),
                TodayMeetingFact(date: scl(4, 10), durationSeconds: 1800),
                TodayMeetingFact(date: scl(3, 10), durationSeconds: 1800),
            ],
            dictationDays: [],
            now: dstDayNow,
            calendar: santiago
        )
        assertEqual(onDstDay.dailyActivity.count, 7, "all 7 bars are emitted on the DST day")
        assertEqual(onDstDay.dailyActivity.suffix(4).map(\.meetings), [1, 1, 1, 1], "none of the prior days drop out when subtracting from 01:00")
        assertEqual(onDstDay.streak.currentDays, 4, "current streak crosses midnight-skip DST day intact")
        assertEqual(onDstDay.streak.longestDays, 4, "longest streak crosses midnight-skip DST day intact")
        assertEqual(TodayCopy.rowWhen(for: scl(5, 14), now: dstDayNow, locale: locale, calendar: santiago), "Yesterday", "Sep 5 is Yesterday on Sep 6")

        // Next midnight after Sep 6 (01:00) must be Sep 7 00:00, not 01:00.
        let sep7Midnight = TodayClockPolicy.nextMidnight(after: dstDayNow, calendar: santiago)
        assertEqual(santiago.component(.day, from: sep7Midnight), 7, "nextMidnight lands on Sep 7")
        assertEqual(santiago.component(.hour, from: sep7Midnight), 0, "nextMidnight lands at 00:00 on Sep 7")

        // Two days later (Sep 8), the 7-day window and streak span across Sep 6.
        let afterDstNow = scl(8, 15)
        let acrossDst = TodayStatsBuilder.buildOverview(
            meetings: [
                TodayMeetingFact(date: scl(8, 10), durationSeconds: 1800),
                TodayMeetingFact(date: scl(7, 10), durationSeconds: 1800),
                TodayMeetingFact(date: scl(6, 10), durationSeconds: 1800),
                TodayMeetingFact(date: scl(5, 10), durationSeconds: 1800),
                TodayMeetingFact(date: scl(4, 10), durationSeconds: 1800),
            ],
            dictationDays: [],
            now: afterDstNow,
            calendar: santiago
        )
        assertEqual(acrossDst.dailyActivity.count, 7, "all 7 bars are emitted spanning Sep 6")
        assertEqual(acrossDst.dailyActivity.suffix(5).map(\.meetings), [1, 1, 1, 1, 1], "Sep 6 bar is present and matched by startOfDay")
        assertEqual(acrossDst.streak.currentDays, 5, "current streak spanning Sep 6 stays unbroken")
        assertEqual(acrossDst.streak.longestDays, 5, "longest streak spanning Sep 6 stays unbroken")
        assertEqual(TodayCopy.rowWhen(for: scl(6, 14), now: scl(7, 15), locale: locale, calendar: santiago), "Yesterday", "Sep 6 is Yesterday on Sep 7")
    }

    runSuite("TodayStatsBarLayout - stacked bar and capture mix clamping never overflow container") {
        // Skewed 3-segment stacked bar at max height (68pt, spacing 1.5pt, floor 3pt).
        let barHeights = TodayStatsBarLayout.segmentSizes(
            weights: [1, 1, 100],
            totalSize: 68,
            spacing: 1.5,
            minimumSegment: 3
        )
        assertEqual(barHeights.count, 3, "three segments returned")
        assertTrue(barHeights.allSatisfy { $0 >= 3 - 0.0001 }, "every segment keeps its 3pt minimum when budget allows")
        let barTotal = barHeights.reduce(0, +) + 1.5 * 2
        assertTrue(barTotal <= 68 + 0.0001, "stacked bar height + spacing (\(barTotal)) never exceeds 68pt")

        // Tiny 3-segment stacked bar (8pt total, spacing 1.5pt -> 5pt available for 3 segments).
        let tinyBar = TodayStatsBarLayout.segmentSizes(
            weights: [1, 1, 1],
            totalSize: 8,
            spacing: 1.5,
            minimumSegment: 3
        )
        assertTrue(tinyBar.allSatisfy { $0 > 0 }, "tiny bar segments stay positive")
        let tinyTotal = tinyBar.reduce(0, +) + 1.5 * 2
        assertTrue(tinyTotal <= 8 + 0.0001, "tiny stacked bar (\(tinyTotal)) never exceeds scaledHeight 8pt")

        // Capture Mix with 4pt minimum floor on skewed shares (204pt wide, spacing 2pt).
        let mixWidths = TodayStatsBarLayout.segmentSizes(
            weights: [0.99, 0.005, 0.005],
            totalSize: 204,
            spacing: 2,
            minimumSegment: 4
        )
        assertEqual(mixWidths.count, 3, "three capture mix segments returned")
        assertTrue(mixWidths[1] >= 4 - 0.0001 && mixWidths[2] >= 4 - 0.0001, "small capture mix segments keep 4pt floor")
        let mixTotal = mixWidths.reduce(0, +) + 2 * 2
        assertTrue(abs(mixTotal - 204) < 0.0001, "capture mix widths + spacing (\(mixTotal)) match container width 204pt without overflow")

        // Zero or narrower-than-spacing containers never produce negative values.
        let collapsed = TodayStatsBarLayout.segmentSizes(
            weights: [1, 2, 3],
            totalSize: 2,
            spacing: 2,
            minimumSegment: 4
        )
        assertEqual(collapsed, [0, 0, 0], "container narrower than spacing clamps cleanly to zero")
    }
}
