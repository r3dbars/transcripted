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

    runSuite("TodaySessionBuilder - a pause over 30 minutes starts a new session") {
        func item(_ kind: TodayRecentItem.Kind, _ id: String, _ at: Date, seconds: Int? = nil, app: String? = nil, text: String? = nil) -> TodayRecentItem {
            TodayRecentItem(kind: kind, id: id, title: id, date: at, durationSeconds: seconds, transcriptURL: nil, preview: text, appName: app)
        }
        let sessions = TodaySessionBuilder.sessions([
            item(.dictation, "d3", date(24, 14, 10), text: "Summarize the review"),
            item(.meeting, "Design review", date(24, 13, 0), seconds: 60 * 60),
            item(.dictation, "d1", date(24, 9, 0), text: "Morning"),
            item(.dictation, "d2", date(24, 9, 25), text: "Still morning"),
            item(.writing, "w1", date(24, 16, 0), seconds: 120, app: "Slack"),
            item(.writing, "w2", date(24, 16, 20), seconds: 60, app: "Slack"),
        ])
        assertEqual(sessions.map { $0.items.map(\.id) }, [["d1", "d2"], ["Design review", "d3"], ["w1", "w2"]],
                    "grouped oldest first; a meeting's length keeps the dictation after it in its session")
        assertEqual(sessions.map(\.title), ["Morning", "Design review", "Writing in Slack"], "titles follow the rules")
        assertEqual(sessions[1].kinds, [.meeting, .dictation], "kinds in lane order")
        assertTrue(TodaySessionBuilder.sessions([]).isEmpty, "an empty day has no sessions")
    }

    runSuite("TodaySessionBuilder - titles never end in half a word") {
        let long = "Can you use a workflow for this and then standardize across every agent file in the repo"
        let trimmed = TodaySessionBuilder.wordTrimmed(long, maxLength: 30)
        assertEqual(trimmed, "Can you use a workflow for\u{2026}", "cut at the last whole word")
        assertEqual(TodaySessionBuilder.wordTrimmed("Reply to Sam, then the rest of it", maxLength: 13), "Reply to Sam\u{2026}", "trailing comma dropped")
        assertEqual(TodaySessionBuilder.wordTrimmed("short  text", maxLength: 30), "short text", "short text untouched")
        let early = TodaySessionBuilder.wordTrimmed("a " + String(repeating: "x", count: 100), maxLength: 20)
        assertEqual(early, "a " + String(repeating: "x", count: 18) + "\u{2026}", "no late word break cuts hard instead of leaving just \"a\"")
        let quoted = TodayRecentItem(kind: .dictation, id: "d", title: "\u{201C}Hi there\u{201D}", date: now, durationSeconds: nil, transcriptURL: nil)
        assertEqual(TodaySessionBuilder.line(for: quoted), "Hi there", "dictation quotes are dropped without a preview")
        let mixed = [
            TodayRecentItem(kind: .writing, id: "w1", title: "Notes", date: now, durationSeconds: 60, transcriptURL: nil, appName: "Notes"),
            TodayRecentItem(kind: .writing, id: "w2", title: "Reply", date: now, durationSeconds: 60, transcriptURL: nil, appName: "Mail"),
        ]
        assertEqual(TodaySessionBuilder.title(for: mixed), "Notes", "writing in several apps uses the first entry")
    }

    runSuite("TodaySessionBuilder - a short meeting doesn't name a busy session") {
        let quick = TodayRecentItem(kind: .meeting, id: "Quick notes", title: "Quick notes", date: date(24, 5, 15), durationSeconds: 60, transcriptURL: nil)
        let said = TodayRecentItem(kind: .dictation, id: "d", title: "x", date: date(24, 5, 20), durationSeconds: nil, transcriptURL: nil, preview: "Plan the release notes")
        let sync = TodayRecentItem(kind: .meeting, id: "Sync", title: "Sync", date: date(24, 5, 30), durationSeconds: 20 * 60, transcriptURL: nil)
        assertEqual(TodaySessionBuilder.title(for: [quick, said]), "Plan the release notes", "a 1-minute meeting gives way to the dictation")
        assertEqual(TodaySessionBuilder.title(for: [quick, said, sync]), "Sync", "a real meeting still names it")
        assertEqual(TodaySessionBuilder.title(for: [quick]), "Quick notes", "a short meeting alone keeps its title")
        let slack = TodayRecentItem(kind: .writing, id: "w", title: "Reply", date: date(24, 5, 18), durationSeconds: 60, transcriptURL: nil, appName: "Slack")
        assertEqual(TodaySessionBuilder.title(for: [quick, slack]), "Writing in Slack", "a short meeting doesn't beat one-app writing")
    }

    runSuite("TodayCopy - session times") {
        let range = TodayCopy.sessionTime(start: date(24, 5, 15), end: date(24, 6, 31), locale: locale, calendar: calendar)
        assertTrue(range.contains("5:15") && range.contains("6:31"), "a long session shows its range: \(range)")
        let short = TodayCopy.sessionTime(start: date(24, 5, 15), end: date(24, 5, 17), locale: locale, calendar: calendar)
        assertTrue(short.contains("5:15") && !short.contains("5:17"), "a short one shows its start: \(short)")
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

        let item = { (kind: TodayRecentItem.Kind, id: String, seconds: Int?, app: String?, words: Int?) in
            TodayRecentItem(kind: kind, id: id, title: id, date: date(20, 10), durationSeconds: seconds, transcriptURL: nil, appName: app, words: words)
        }
        let friday = TodayTapeBuilder.days(
            captures: [
                item(.meeting, "m", 30 * 60, nil, nil),
                item(.dictation, "d", nil, nil, 8),
                item(.writing, "w1", 60, "Notes", 40),
                item(.writing, "w2", 60, "Slack", 60),
            ],
            now: now,
            calendar: calendar
        ).first { calendar.isDate($0.day, inSameDayAs: date(20)) }
        let dayStats = friday.map(TodayTapeBuilder.dayStats)
        assertEqual(dayStats?.todayMeetings, 1, "the day's meetings")
        assertEqual(dayStats?.todayMeetingMinutes, 30, "the day's meeting minutes")
        assertEqual(dayStats?.todayDictations, 1, "the day's dictations")
        assertEqual(dayStats?.todayWritingWords, 100, "the day's words written")
        assertEqual(dayStats?.todayWritingApps.map(\.appName), ["Slack", "Notes"], "the day's apps by words")
        assertEqual(TodayCopy.weekdayLong(for: date(20), locale: locale, calendar: calendar), "Sunday", "long weekday")
    }
}
