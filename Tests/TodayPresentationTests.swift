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

    // A small mixed week shared by the day-card suites below. Thursday the
    // 24th is today; Tuesday the 22nd only has two captures from before 6 AM.
    func tapeItem(_ kind: TodayRecentItem.Kind, _ id: String, _ at: Date, _ seconds: Int? = nil) -> TodayRecentItem {
        TodayRecentItem(kind: kind, id: id, title: id, date: at, durationSeconds: seconds, transcriptURL: nil,
                        appName: kind == .writing ? "Notes" : nil, words: kind == .meeting ? nil : 12)
    }
    let tapeCaptures: [TodayRecentItem] = [
        // Before 6 AM both clamp to the left edge (start 0). By date "z-early"
        // comes first and it's a meeting (listed first), so only the id puts
        // "a-early" ahead of it.
        tapeItem(.meeting, "z-early", date(24, 2), 10 * 60),
        tapeItem(.dictation, "a-early", date(24, 5)),
        tapeItem(.meeting, "m-0900", date(24, 9), 60 * 60),
        tapeItem(.dictation, "d-0930", date(24, 9, 30)),
        tapeItem(.writing, "w-1000", date(24, 10), 120),
        tapeItem(.dictation, "d-1200", date(24, 12)),
        tapeItem(.meeting, "m-1400", date(24, 14), 42 * 60),
        tapeItem(.writing, "w-1600", date(24, 16), 60),
        tapeItem(.dictation, "tue-z", date(22, 2)),
        tapeItem(.writing, "tue-a", date(22, 5), 60),
        tapeItem(.meeting, "mon-sync", date(21, 13, 10), 30 * 60),
    ]
    let tapeWeek = TodayTapeBuilder.days(captures: tapeCaptures, now: now, calendar: calendar, locale: locale)
    func tapeDay(_ day: Int) -> TodayTapeDay? {
        tapeWeek.first { calendar.isDate($0.day, inSameDayAs: date(day)) }
    }

    runSuite("A built day keeps its marks in time order, ties by id") {
        guard let today = tapeDay(24) else {
            assertTrue(false, "today is in the week")
            return
        }
        assertEqual(
            today.allMarks.map(\.id),
            ["a-early", "z-early", "m-0900", "d-0930", "w-1000", "d-1200", "m-1400", "w-1600"],
            "every lane interleaved by start; the two pre-6 AM marks tie at 0 and sort by id"
        )
        let lanes = today.meetings + today.dictations + today.writing
        assertEqual(today.allMarks.count, lanes.count, "no mark is dropped or doubled")
        assertEqual(Set(today.allMarks.map(\.id)), Set(lanes.map(\.id)), "allMarks is exactly the three lanes")
        for mark in today.allMarks {
            assertTrue(lanes.contains(mark), "\(mark.id) in allMarks is the same mark as in its lane")
        }
        let starts = today.allMarks.map(\.start)
        assertEqual(starts, starts.sorted(), "starts never go backwards")

        assertEqual(tapeDay(22)?.allMarks.map(\.id) ?? ["missing day"], ["tue-a", "tue-z"], "an earlier day ties by id too")
        assertEqual(tapeDay(21)?.allMarks.map(\.id) ?? ["missing day"], ["mon-sync"], "a one-mark day")
        assertEqual(tapeDay(20)?.allMarks.map(\.id) ?? ["missing day"], [String](), "an empty day has no marks")
    }

    runSuite("Each mark carries its hover line, made with the day") {
        var checked = 0
        for day in tapeWeek {
            for mark in day.allMarks {
                assertEqual(
                    mark.hoverText,
                    TodayTapeBuilder.markDescription(mark, now: now, locale: locale, calendar: calendar),
                    "\(mark.id) carries the same hover line the builder describes"
                )
                checked += 1
            }
        }
        assertEqual(checked, tapeCaptures.count, "today's and earlier days' marks were all checked")

        // The locale handed to days(...) is the one the hover line uses: a
        // 24-hour locale writes 2 PM differently from en_US_POSIX.
        let german = Locale(identifier: "de_DE")
        let germanWeek = TodayTapeBuilder.days(captures: tapeCaptures, now: now, calendar: calendar, locale: german)
        let germanMeeting = germanWeek.last?.meetings.first { $0.id == "m-1400" }
        assertNotNil(germanMeeting, "the 2 PM meeting is on today's tape")
        if let germanMeeting {
            assertEqual(
                germanMeeting.hoverText,
                TodayTapeBuilder.markDescription(germanMeeting, now: now, locale: german, calendar: calendar),
                "the hover line follows the locale the day was built with"
            )
        }
        let tuesdayMark = tapeDay(22)?.allMarks.first
        assertTrue(tuesdayMark.map { !$0.hoverText.isEmpty } ?? false, "an earlier day's mark has a hover line")
    }

    runSuite("The day card shows the hovered mark, else the picked one, else the day's latest") {
        guard let today = tapeDay(24), let tuesday = tapeDay(22), let sunday = tapeDay(20) else {
            assertTrue(false, "the week has the days the suite needs")
            return
        }

        let idle = TodayTapeSelection(day: today, pickedID: nil, hoveredID: nil)
        assertEqual(idle.picked?.id, "w-1600", "nothing picked: the day's latest capture")
        assertEqual(idle.shown?.id, "w-1600", "nothing hovered: shows the picked (latest) one")

        let picked = TodayTapeSelection(day: today, pickedID: "m-0900", hoveredID: nil)
        assertEqual(picked.picked?.id, "m-0900", "a picked mark is picked")
        assertEqual(picked.shown?.id, "m-0900", "and shown")

        let hovering = TodayTapeSelection(day: today, pickedID: "m-0900", hoveredID: "d-1200")
        assertEqual(hovering.shown?.id, "d-1200", "a hover wins for what's shown")
        assertEqual(hovering.picked?.id, "m-0900", "while the pick stays put")

        let hoverWithoutPick = TodayTapeSelection(day: today, pickedID: nil, hoveredID: "z-early")
        assertEqual(hoverWithoutPick.shown?.id, "z-early", "a hover with nothing picked")
        assertEqual(hoverWithoutPick.picked?.id, "w-1600", "picked still falls back to the latest")

        let stalePick = TodayTapeSelection(day: today, pickedID: "not-on-this-day", hoveredID: nil)
        assertEqual(stalePick.picked?.id, "w-1600", "an unknown pick falls back to the latest")
        assertEqual(stalePick.shown?.id, "w-1600", "and that's what's shown")

        let staleHover = TodayTapeSelection(day: today, pickedID: "m-0900", hoveredID: "gone")
        assertEqual(staleHover.shown?.id, "m-0900", "an unknown hover shows the pick")

        // Both Tuesday marks clamp to start 0, so allMarks puts "tue-a" (5 AM)
        // first by id. The latest by capture time is "tue-a"; "tue-z" (2 AM)
        // must not win just because it sorts last on the tape.
        let tuesdayIdle = TodayTapeSelection(day: tuesday, pickedID: nil, hoveredID: nil)
        assertEqual(tuesdayIdle.picked?.id, "tue-a", "latest means the latest capture time, not the last mark on the tape")
        assertEqual(tuesdayIdle.shown?.id, "tue-a", "and it's shown")

        let emptyInputs: [(String?, String?)] = [(nil, nil), ("x", nil), (nil, "y"), ("x", "y")]
        for (pickedID, hoveredID) in emptyInputs {
            let empty = TodayTapeSelection(day: sunday, pickedID: pickedID, hoveredID: hoveredID)
            let label = "\(String(describing: pickedID)), \(String(describing: hoveredID))"
            assertNil(empty.picked, "an empty day picks nothing (\(label))")
            assertNil(empty.shown, "an empty day shows nothing (\(label))")
            assertNil(empty.shownIndex, "an empty day has no position (\(label))")
        }
        assertEqual(
            TodayTapeSelection(day: today, pickedID: "d-0930", hoveredID: nil),
            TodayTapeSelection(day: today, pickedID: "d-0930", hoveredID: nil),
            "the same inputs make the same selection"
        )
    }

    runSuite("Prev and Next step through the day in time order") {
        guard let today = tapeDay(24) else {
            assertTrue(false, "today is in the week")
            return
        }
        for (index, mark) in today.allMarks.enumerated() {
            assertEqual(
                TodayTapeSelection(day: today, pickedID: mark.id, hoveredID: nil).shownIndex, index,
                "picking \(mark.id) puts the card at its place in the day"
            )
            assertEqual(
                TodayTapeSelection(day: today, pickedID: "m-0900", hoveredID: mark.id).shownIndex, index,
                "hovering \(mark.id) moves the position with what's shown"
            )
        }
        let idle = TodayTapeSelection(day: today, pickedID: nil, hoveredID: nil)
        assertEqual(idle.shownIndex, today.allMarks.count - 1, "the latest capture sits at the end of today's tape")

        // Walk Prev from the latest to the first, then Next back, the way the card does.
        let tapeOrder = today.allMarks.map(\.id)
        var walkedBack: [String] = []
        var selection = idle
        while let index = selection.shownIndex, tapeOrder.indices.contains(index), walkedBack.count <= tapeOrder.count {
            walkedBack.append(tapeOrder[index])
            guard index > 0 else { break }
            selection = TodayTapeSelection(day: today, pickedID: tapeOrder[index - 1], hoveredID: nil)
        }
        assertEqual(walkedBack, Array(tapeOrder.reversed()), "Prev visits every mark, newest to oldest")
        var walkedForward: [String] = []
        while let index = selection.shownIndex, tapeOrder.indices.contains(index), walkedForward.count <= tapeOrder.count {
            walkedForward.append(tapeOrder[index])
            guard index + 1 < tapeOrder.count else { break }
            selection = TodayTapeSelection(day: today, pickedID: tapeOrder[index + 1], hoveredID: nil)
        }
        assertEqual(walkedForward, tapeOrder, "Next walks forward in time order")

        if let tuesday = tapeDay(22) {
            let tuesdayIdle = TodayTapeSelection(day: tuesday, pickedID: nil, hoveredID: nil)
            assertEqual(tuesdayIdle.shownIndex, 0, "the latest capture can sit before a tie that sorts after it")
        }
    }

    runSuite("TodayTapeDay - sessions come with the day, and a new capture breaks equality") {
        func item(_ kind: TodayRecentItem.Kind, _ id: String, _ at: Date, _ seconds: Int? = nil) -> TodayRecentItem {
            TodayRecentItem(kind: kind, id: id, title: id, date: at, durationSeconds: seconds, transcriptURL: nil)
        }
        let captures = [
            item(.dictation, "d-b", date(24, 3)),          // before 6 AM: both clamp to the left edge
            item(.dictation, "d-a", date(24, 4)),
            item(.writing, "w", date(24, 9), 60),
            item(.meeting, "m", date(24, 9), 30 * 60),     // same minute as the writing entry
            item(.dictation, "d-c", date(24, 9, 10)),
        ]
        let today = TodayTapeBuilder.days(captures: captures, now: now, calendar: calendar).last
        assertEqual(today?.sessions.map { $0.items.map(\.id) }, [["d-b"], ["d-a"], ["m", "w", "d-c"]], "sessions split at a 30-minute pause")
        assertEqual(today?.sessions.map(\.title), ["d-b", "d-a", "m"], "session titles by rule")
        assertEqual(today?.sessions, TodaySessionBuilder.sessions(today?.allMarks.map(\.item) ?? []), "same sessions as building them from the marks")

        let later = TodayTapeBuilder.days(
            captures: captures + [item(.dictation, "d-new", date(24, 14))],
            now: now,
            calendar: calendar
        ).last
        assertEqual(later?.id, today?.id, "a new capture keeps the day's id")
        assertTrue(later != today, "but the day no longer compares equal, so the card redraws")
        assertEqual(later?.allMarks.last?.id, "d-new", "the new capture is on the tape")
    }

    runSuite("TodayCopy.minuteKey - equal keys never hide a change in the day card's time copy") {
        let utc = TimeZone(identifier: "UTC")!
        var utcCalendar = Calendar(identifier: .gregorian)
        utcCalendar.timeZone = utc
        // 15:00 UTC on Oct 3, 2026 is 01:30 on Lord Howe, half an hour before
        // its 30-minute DST jump, so the hour below crosses it.
        let start = utcCalendar.date(from: DateComponents(year: 2026, month: 10, day: 3, hour: 15, minute: 0, second: 0))!
        var hidden = 0
        var changes = 0
        for zone in ["UTC", "America/Los_Angeles", "Asia/Kathmandu", "America/St_Johns", "Australia/Lord_Howe"] {
            var zoned = Calendar(identifier: .gregorian)
            zoned.timeZone = TimeZone(identifier: zone)!
            var previous = start.addingTimeInterval(-1)
            var previousText = TodayCopy.rowWhen(for: previous, now: previous, locale: locale, calendar: zoned)
            for second in 0..<3_600 {
                let instant = start.addingTimeInterval(TimeInterval(second))
                let text = TodayCopy.rowWhen(for: instant, now: instant, locale: locale, calendar: zoned)
                if text != previousText {
                    changes += 1
                    if TodayCopy.minuteKey(instant) == TodayCopy.minuteKey(previous) { hidden += 1 }
                }
                previous = instant
                previousText = text
            }
        }
        assertEqual(hidden, 0, "every change of the Now label lands on a new minute key")
        assertTrue(changes >= 5 * 60, "the label changed every minute in every zone")
    }

    runSuite("TodayWritingParser - Captured keeps the exact millisecond") {
        let posix = DateFormatter()
        posix.locale = Locale(identifier: "en_US_POSIX")
        posix.timeZone = TimeZone(identifier: "UTC")
        posix.dateFormat = "yyyy-MM-dd'T'HH:mm:ss"
        func captured(_ ms: Int64) -> String {
            let seconds = ms / 1_000
            let rest = Int(ms % 1_000)
            let millis = rest < 10 ? "00\(rest)" : (rest < 100 ? "0\(rest)" : "\(rest)")
            return posix.string(from: Date(timeIntervalSince1970: TimeInterval(seconds))) + "." + millis + "Z"
        }
        func dayFile(_ capturedValues: [String]) -> String {
            var text = "# Writing\n"
            for (index, value) in capturedValues.enumerated() {
                text += "\n## 10:00 AM - Entry\n\nEntry ID: `w-\(index)`\nCaptured: \(value)\nSource app: Notes\nWords: 1\n\nword\n"
            }
            return text
        }

        var values: [Int64] = (0..<1_000).map { 1_790_265_900_000 + Int64($0) }   // every ms of one second
        var seed: UInt64 = 0x2545_F491_4F6C_DD1D
        for _ in 0..<2_000 {                                                      // 2000 to 2100, fixed LCG
            seed = seed &* 6_364_136_223_846_793_005 &+ 1_442_695_040_888_963_407
            values.append(946_684_800_000 + Int64(seed >> 20) % 3_155_760_000_000)
        }
        for zone in ["America/Chicago", "Asia/Kathmandu", "Australia/Adelaide"] {  // local midnight +/- 1 ms
            var zoned = Calendar(identifier: .gregorian)
            zoned.timeZone = TimeZone(identifier: zone)!
            let midnight = zoned.date(from: DateComponents(year: 2026, month: 9, day: 24))!
            let ms = Int64(midnight.timeIntervalSince1970 * 1_000)
            values += [ms - 1, ms, ms + 1]
        }

        let strings = values.map(captured)
        let entries = TodayWritingParser.entries(fromDayFile: dayFile(strings))
        assertEqual(entries.count, values.count, "every entry parses")
        let reference = ISO8601DateFormatter()
        reference.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        var offExact = 0
        var offReference = 0
        for (index, entry) in entries.enumerated() where index < values.count {
            if entry.date != Date(timeIntervalSince1970: Double(values[index]) / 1_000) { offExact += 1 }
            if entry.date != reference.date(from: strings[index]) { offReference += 1 }
        }
        assertEqual(offExact, 0, "each date is exactly its millisecond")
        assertEqual(offReference, 0, "each date matches ISO8601DateFormatter bit for bit")

        let offsets = TodayWritingParser.entries(fromDayFile: dayFile([
            "2026-09-24T16:05:00.387Z",
            "2026-09-24T16:05:00.387+00:00",
            "2026-09-24T11:05:00.387-05:00",
            "2026-09-24T11:05:00-05:00",
        ]))
        let instant = Date(timeIntervalSince1970: 1_790_265_900.387)
        assertEqual(offsets.map(\.date), [instant, instant, instant, Date(timeIntervalSince1970: 1_790_265_900)], "offsets parse to the same instant")

        let rejected = TodayWritingParser.entries(fromDayFile: dayFile(["2026-09-24 16:05:00.387Z", "not a date"]))
        assertTrue(rejected.isEmpty, "out-of-format Captured values make no entry")
    }
}
