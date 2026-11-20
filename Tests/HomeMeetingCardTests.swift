// The Meetings page (QuietMeetingCard and its rows): day headers, what fills
// a closed row's summary slot, the opened card's subtitle and menu, one open
// row at a time with its transcript closed on open, and when the titles
// opt-in line shows (HomeMeetingCardPresentation). Fictional names only.

import Foundation

func testHomeMeetingCard() {
    let start = Date(timeIntervalSinceReferenceDate: 800_000_000)
    typealias P = HomeMeetingCardPresentation

    // Days and times read through an injected clock (calendar, locale, time
    // zone, now), never the wall clock.
    let pacific = TimeZone(identifier: "America/Los_Angeles")!
    let usEnglish = Locale(identifier: "en_US")
    func clock(_ year: Int, _ month: Int, _ day: Int, _ hour: Int = 12, _ minute: Int = 0,
               locale: Locale = usEnglish, timeZone: TimeZone = pacific) -> MeetingsPageClock {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = timeZone
        let now = calendar.date(from: DateComponents(year: year, month: month, day: day, hour: hour, minute: minute))!
        return MeetingsPageClock(now: now, locale: locale, timeZone: timeZone)
    }
    func at(_ year: Int, _ month: Int, _ day: Int, _ hour: Int, _ minute: Int = 0, _ second: Int = 0,
            timeZone: TimeZone = pacific) -> Date {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = timeZone
        return calendar.date(from: DateComponents(year: year, month: month, day: day, hour: hour, minute: minute, second: second))!
    }

    runSuite("Meetings group by day: Today, Yesterday, then the weekday and date") {
        let now = clock(2026, 11, 18, 15)
        assertEqual(P.dayHeader(for: at(2026, 11, 18, 9), clock: now), "Today")
        assertEqual(P.dayHeader(for: at(2026, 11, 17, 22), clock: now), "Yesterday")
        assertEqual(P.dayHeader(for: at(2026, 11, 16, 13), clock: now), "Monday, Nov 16", "older days this year: weekday and date, no year")
    }

    runSuite("Day headers move at midnight: a minute either side of it") {
        let justAfter = clock(2026, 11, 18, 0, 1)
        assertEqual(P.dayHeader(for: at(2026, 11, 17, 23, 59), clock: justAfter), "Yesterday",
                    "a meeting at 11:59 PM is yesterday once the clock passes midnight")
        assertEqual(P.dayHeader(for: at(2026, 11, 18, 0, 0, 30), clock: justAfter), "Today")
        let justBefore = clock(2026, 11, 17, 23, 59)
        assertEqual(P.dayHeader(for: at(2026, 11, 17, 23, 30), clock: justBefore), "Today",
                    "the same meeting was today a minute before midnight")
        assertEqual(P.dayHeader(for: at(2026, 11, 16, 23, 59), clock: justBefore), "Yesterday")
    }

    runSuite("A day from another year says the year, so two Nov 16s never look the same") {
        let newYear = clock(2027, 1, 2, 10)
        assertEqual(P.dayHeader(for: at(2027, 1, 1, 20), clock: newYear), "Yesterday")
        assertEqual(P.dayHeader(for: at(2026, 12, 31, 20), clock: newYear), "Thursday, Dec 31, 2026",
                    "across the year boundary the year is spelled out")
        let thisYear = clock(2026, 11, 18)
        assertEqual(P.dayHeader(for: at(2025, 11, 16, 13), clock: thisYear), "Sunday, Nov 16, 2025")
        assertEqual(P.dayHeader(for: at(2026, 11, 16, 13), clock: thisYear), "Monday, Nov 16")
        assertFalse(
            P.dayHeader(for: at(2025, 11, 16, 13), clock: thisYear) == P.dayHeader(for: at(2026, 11, 16, 13), clock: thisYear),
            "the same date in two years reads differently"
        )
    }

    runSuite("Times follow the Mac's 12- or 24-hour setting and its locale") {
        let start = at(2026, 11, 18, 14)
        let twelve = P.timeText(for: start, clock: clock(2026, 11, 18))
        assertTrue(twelve.hasPrefix("2:00") && twelve.hasSuffix("PM"), "US English reads 2:00 PM (got \(twelve))")
        assertEqual(P.timeText(for: start, clock: clock(2026, 11, 18, locale: Locale(identifier: "en_US@hours=h23"))), "14:00",
                    "a 24-hour Mac reads 14:00")
        assertEqual(P.timeText(for: start, clock: clock(2026, 11, 18, locale: Locale(identifier: "en_GB"))), "14:00")
        assertEqual(P.dayHeader(for: at(2026, 11, 16, 13), clock: clock(2026, 11, 18, locale: Locale(identifier: "en_GB"))),
                    "Monday 16 Nov", "the date takes the locale's own order")
        let tokyo = TimeZone(identifier: "Asia/Tokyo")!
        assertEqual(P.timeText(for: start, clock: clock(2026, 11, 18, locale: Locale(identifier: "en_US@hours=h23"), timeZone: tokyo)), "07:00",
                    "the same moment reads in the Mac's time zone")
    }

    runSuite("Days and times stay right across a daylight-saving change") {
        // Clocks go back at 2:00 AM on Sunday, Nov 1, 2026 in California:
        // that day is 25 hours long.
        let sunday = clock(2026, 11, 1, 23, 30)
        let early = at(2026, 11, 1, 0, 30)
        let late = at(2026, 11, 1, 23, 0)
        assertEqual(P.dayHeader(for: early, clock: sunday), "Today")
        assertEqual(P.dayHeader(for: late, clock: sunday), "Today")
        assertEqual(P.dayHeader(for: at(2026, 10, 31, 23, 30), clock: sunday), "Yesterday")
        assertEqual(P.timeText(for: late, clock: clock(2026, 11, 1, locale: Locale(identifier: "en_US@hours=h23"))), "23:00")
        let sections = P.daySections([late, early, at(2026, 10, 31, 23, 30)], date: { $0 }, clock: sunday)
        assertEqual(sections.map(\.label), ["Today", "Yesterday"], "the long day is one section")
        assertEqual(sections.first?.items.count, 2)
        // Clocks go forward on Sunday, Mar 8, 2026 (a 23-hour day).
        let spring = clock(2026, 3, 9, 8)
        assertEqual(P.dayHeader(for: at(2026, 3, 8, 23, 30), clock: spring), "Yesterday")
        assertEqual(P.dayHeader(for: at(2026, 3, 7, 23, 30), clock: spring), "Saturday, Mar 7")
    }

    runSuite("Each row carries its section's header, so VoiceOver says the same day") {
        let now = clock(2026, 11, 18, 0, 1)
        let sections = P.daySections(
            [at(2026, 11, 18, 0, 0, 30), at(2026, 11, 17, 23, 59), at(2025, 11, 16, 9)],
            date: { $0 }, clock: now
        )
        assertEqual(sections.map(\.label), ["Today", "Yesterday", "Sunday, Nov 16, 2025"])
        for section in sections {
            for row in section.items {
                assertEqual(row.dayHeader, section.label, "a row's day is its header's text")
            }
        }
        let yesterdayRow = sections[1].items[0]
        assertEqual(
            P.accessibilityLabel(title: "Weekly sync", dayHeader: yesterdayRow.dayHeader,
                                 time: P.timeText(for: yesterdayRow.item, clock: now), start: nil, end: nil),
            "Weekly sync, yesterday \(P.timeText(for: yesterdayRow.item, clock: now))"
        )
    }

    runSuite("A closed row shows the summary line when the meeting has one") {
        assertEqual(
            P.savedSlot(
                summaryLine: "  Team tier comes off the page. Pro price gets tested at two points. ",
                start: start, end: start.addingTimeInterval(48 * 60), people: ["You", "Marcus"]
            ),
            .summary("Team tier comes off the page. Pro price gets tested at two points.")
        )
    }

    runSuite("Without a summary line the slot says length and people") {
        let people = P.people(speakerNames: ["Marcus", "Priya"], isImported: false)
        assertEqual(people, ["You", "Marcus", "Priya"], "a recorded meeting leads with You, the mic track")
        assertEqual(
            P.savedSlot(summaryLine: nil, start: start, end: start.addingTimeInterval(48 * 60), people: people),
            .fallback("48 min \u{00B7} You, Marcus, Priya")
        )
        assertEqual(
            P.savedSlot(summaryLine: "   ", start: start, end: start.addingTimeInterval(48 * 60), people: people),
            .fallback("48 min \u{00B7} You, Marcus, Priya"),
            "a blank line counts as no line"
        )
        assertEqual(P.fallbackLine(start: nil, end: nil, people: ["You"]), "You", "no length leaves the people")
        assertEqual(P.fallbackLine(start: start, end: start.addingTimeInterval(20 * 60), people: []), "20 min")
        assertEqual(P.savedSlot(summaryLine: nil, start: nil, end: nil, people: []), .empty)
        assertEqual(
            P.people(speakerNames: ["Speaker 2", "Dana", "dana"], isImported: true),
            ["Dana"],
            "an imported file has no mic track, and unnamed or repeated voices are left out"
        )
    }

    runSuite("A named mic voice stands in for You instead of being listed twice") {
        assertEqual(P.people(speakerNames: ["Dana", "Marcus"], micVoices: ["Dana"], isImported: false), ["Dana", "Marcus"],
                    "the mic's only voice was named Dana: one person, not You and Dana")
        assertEqual(P.people(speakerNames: ["Marcus"], micVoices: ["You"], isImported: false), ["You", "Marcus"])
        assertEqual(P.people(speakerNames: ["Dana", "Marcus"], micVoices: ["You", "Dana"], isImported: false), ["You", "Dana", "Marcus"],
                    "a second person on the mic (split local speakers) still leaves You")
        assertEqual(P.people(speakerNames: ["Marcus"], micVoices: ["Speaker 2"], isImported: false), ["You", "Marcus"],
                    "an unnamed mic voice is you")
        assertEqual(P.people(speakerNames: ["Marcus"], micVoices: [], isImported: false), ["You", "Marcus"],
                    "files that don't mark channels still lead with You")
        assertEqual(
            P.openedSubtitle(time: "2:00 PM", start: nil, end: nil,
                             people: P.people(speakerNames: ["Dana"], micVoices: ["Dana"], isImported: false)),
            "2:00 PM \u{00B7} Dana"
        )
        assertEqual(
            RecentMeetingSpeakerStatus.micVoices(fromLabels: ["Mic/Dana", "System/Marcus", "mic/dana", "Mic/You", "Priya"]),
            ["Dana", "You"],
            "the mic track's voices, once each, as written"
        )
        var item = RecentMeetingItem(
            title: "1:1 with Dana", date: start, startDate: nil, endDate: nil,
            transcriptURL: URL(fileURLWithPath: "/tmp/fictional-one-on-one.md"), audio: nil, speakerStatus: .ready
        )
        item.micVoices = ["Dana"]
        let cached = CachedRecentMeetingMetadata(item: item)
        assertEqual(cached.makeItem(transcriptURL: item.transcriptURL, audio: nil).micVoices, ["Dana"], "the cache keeps the mic voices")
        if let encoded = try? JSONEncoder().encode(cached),
           var object = (try? JSONSerialization.jsonObject(with: encoded)) as? [String: Any] {
            object.removeValue(forKey: "micVoices")
            let legacy = (try? JSONSerialization.data(withJSONObject: object)) ?? Data()
            assertNil(try? JSONDecoder().decode(CachedRecentMeetingMetadata.self, from: legacy),
                      "a cached row from before mic voices misses once, so the meeting is reparsed")
        } else {
            assertTrue(false, "payload should encode")
        }
        assertEqual(P.participantsText(["You", "Priya", "Leo", "Sam", "Ana"]), "You, Priya, Leo +2")
    }

    runSuite("Failed meetings put the existing amber wording in the slot") {
        func slot(retryable: Bool, retrying: Bool = false, audio: Bool, usable: FailedMeetingUsableAudio = .unknown) -> P.Slot {
            let presentation = HomeFailedMeetingInlinePresentation.make(
                isRetryable: retryable, isRetrying: retrying, hasAudioFiles: audio,
                detail: "The recording stopped early.", usableAudio: usable
            )
            return P.failedSlot(presentation, isRetrying: retrying)
        }
        assertEqual(slot(retryable: true, audio: true), .problem("Not transcribed", actionTitle: "Try again"))
        assertEqual(slot(retryable: true, retrying: true, audio: true), .working("Retrying", percent: nil))
        assertEqual(slot(retryable: true, audio: true, usable: .absent), .problem("No sound saved", actionTitle: nil))
        assertEqual(slot(retryable: true, audio: false), .problem("Audio missing", actionTitle: nil))
        assertEqual(slot(retryable: false, audio: true), .problem("Needs attention", actionTitle: nil))
    }

    runSuite("The working row says transcribing with its percent, or the failure in amber") {
        assertEqual(P.workingSlot(status: "Transcribing", percent: 42, isCaution: false), .working("Transcribing", percent: 42))
        assertEqual(P.workingSlot(status: "Saved", percent: nil, isCaution: false), .working("Saved", percent: nil))
        assertEqual(P.workingSlot(status: "Needs attention", percent: nil, isCaution: true), .problem("Needs attention", actionTitle: nil))
    }

    runSuite("The opened card's subtitle is time, length and people") {
        assertEqual(
            P.openedSubtitle(time: "2:00 PM", start: start, end: start.addingTimeInterval(48 * 60), people: ["You", "Marcus", "Priya"]),
            "2:00 PM \u{00B7} 48 min \u{00B7} You, Marcus, Priya"
        )
        assertEqual(P.openedSubtitle(time: "9:30 AM", start: nil, end: nil, people: []), "9:30 AM")
        assertEqual(P.durationText(start: start, end: start.addingTimeInterval(65 * 60)), "1 hr 5 min")
        assertEqual(P.durationText(start: start, end: start.addingTimeInterval(10)), "<1 min")
        assertEqual(P.durationText(start: start, end: start), nil, "no length without a real span")
        assertEqual(P.durationSeconds(start: start, end: start.addingTimeInterval(90)), 90)
    }

    runSuite("The opened card's menu holds exactly today's items, in order") {
        let entries = HomeRowMenuPolicy.meetingEntries(
            hasPendingSpeakerReview: true,
            offersMicBoost: true,
            hasAudioRevealTarget: true,
            hasRetranscriptionInput: true,
            isStarred: false
        )
        assertEqual(
            P.openedMenuEntries(entries),
            [.renameMeeting, .reviewSpeakers, .retranscribe, .starMeeting, .showTranscript, .deleteMeeting],
            "Show audio in Finder is Option on Show in Finder, Boost mic rides the amber line"
        )
        assertTrue(entries.contains(.showAudio) && entries.contains(.boostMic), "both stay reachable")
        let kept = HomeRowMenuPolicy.meetingEntries(
            hasPendingSpeakerReview: false, offersMicBoost: false,
            hasAudioRevealTarget: false, hasRetranscriptionInput: false, isStarred: true
        )
        assertEqual(P.openedMenuEntries(kept), [.renameMeeting, .unstarMeeting, .showTranscript, .deleteMeeting],
                    "a meeting that keeps its audio can always turn Keep audio off")
        assertTrue(HomeRowMenuEntry.unstarMeeting.isChecked, "Keep audio shows its check when on")
    }

    runSuite("Only one row is open at a time, and opening starts with the transcript closed") {
        assertEqual(MeetingsPageOpenState.nextOpenID(current: nil, tapped: "a"), "a")
        assertEqual(MeetingsPageOpenState.nextOpenID(current: "a", tapped: "b"), "b", "opening another closes the first")
        assertEqual(MeetingsPageOpenState.nextOpenID(current: "a", tapped: "a"), nil, "clicking the open one closes it")

        var state = MeetingsPageOpenState()
        state.toggleTranscript()
        assertFalse(state.isTranscriptShown, "nothing to reveal with no open row")
        state.sync(openID: "a")
        assertFalse(state.isTranscriptShown(for: "a"), "a just-opened card hides its transcript")
        state.toggleTranscript()
        state.showAllLines()
        assertTrue(state.isTranscriptShown(for: "a"))
        assertTrue(state.showsAllLines(for: "a"))
        assertFalse(state.isTranscriptShown(for: "b"), "only the open row reveals")
        state.sync(openID: "a")
        assertTrue(state.isTranscriptShown(for: "a"), "a redraw of the same open row keeps it")
        state.sync(openID: nil)
        state.sync(openID: "a")
        assertFalse(state.isTranscriptShown(for: "a"), "closing and opening again starts closed")
        assertFalse(state.showsAllLines(for: "a"))
        state.sync(openID: "b")
        assertFalse(state.isTranscriptShown(for: "b"))
        state.toggleTranscript()
        state.showAllLines()
        state.toggleTranscript()
        assertFalse(state.showsAllLines, "hiding the transcript forgets Show all")
    }

    runSuite("Renaming the open meeting keeps it open with its transcript and Show all") {
        var state = MeetingsPageOpenState()
        assertTrue(state.sync(openID: "/m/Weekly sync.md"), "opening is a fresh open")
        state.toggleTranscript()
        state.showAllLines()
        state.followRename(from: "/m/Weekly sync.md", to: "/m/Release plan.md")
        assertFalse(state.sync(openID: "/m/Release plan.md"), "the shell following the rename is not a new open")
        assertTrue(state.isTranscriptShown(for: "/m/Release plan.md"), "the reveal stays open")
        assertTrue(state.showsAllLines(for: "/m/Release plan.md"), "Show all stays")
        assertTrue(state.isOpen("/m/Weekly sync.md", expandedID: "/m/Release plan.md"),
                   "the row still listed under its old path stays open until the list refreshes")
        assertTrue(state.isTranscriptShown(for: "/m/Weekly sync.md"), "and keeps its transcript showing meanwhile")
        assertTrue(state.isOpen("/m/Release plan.md", expandedID: "/m/Release plan.md"))
        assertFalse(state.isOpen("/m/Other.md", expandedID: "/m/Release plan.md"))
        state.sync(openID: "/m/Other.md")
        assertFalse(state.isOpen("/m/Weekly sync.md", expandedID: "/m/Other.md"), "opening another row ends the carry-over")
        assertFalse(state.isTranscriptShown(for: "/m/Other.md"))
        var other = MeetingsPageOpenState()
        other.sync(openID: "/m/A.md")
        other.followRename(from: "/m/B.md", to: "/m/C.md")
        assertEqual(other.openID, "/m/A.md", "renaming a meeting that isn't open changes nothing")
    }

    runSuite("After a rename the open card's preview matches the new open id") {
        let oldURL = URL(fileURLWithPath: "/m/Weekly sync.md")
        let newURL = URL(fileURLWithPath: "/m/2026-06-05 Release plan.md")
        let item = RecentMeetingItem(title: "Weekly sync", date: start, startDate: nil, endDate: nil,
                                     transcriptURL: oldURL, audio: nil, speakerStatus: .ready)
        let loaded = HomeMeetingPreview(item: item, markdown: "# Weekly sync\n\nSome words.")
        var state = MeetingsPageOpenState()
        state.sync(openID: item.id)
        let renamed = loaded.updatingAfterRename(transcriptURL: newURL, title: "Release plan", audio: nil)
        state.followRename(from: item.id, to: newURL.path)
        let openID = newURL.path
        assertEqual(renamed.id, openID, "the renamed preview carries the new open id, so the card isn't stuck loading")
        assertEqual(state.openID, openID)
        assertTrue(state.isOpen(item.id, expandedID: openID) && renamed.id == openID,
                   "the row still listed under its old path shows the renamed preview")
        assertEqual(renamed.markdown, loaded.markdown, "the transcript already read stays")
        assertEqual(renamed.title, "Release plan")
    }

    runSuite("Failed and saved rows share one open slot") {
        let id = UUID(uuidString: "00000000-0000-0000-0000-000000000042")!
        let key = MeetingsPageOpenState.failedMeetingKey(id)
        assertFalse(key.hasPrefix("/"), "never mistaken for a saved meeting's path")
        assertEqual(MeetingsPageOpenState.nextOpenID(current: "/m/Weekly sync.md", tapped: key), key,
                    "opening a failed row closes the open saved one")
        assertEqual(MeetingsPageOpenState.nextOpenID(current: key, tapped: key), nil)
        var state = MeetingsPageOpenState()
        state.sync(openID: key)
        assertFalse(state.isTranscriptShown(for: key))
    }

    runSuite("The transcript reveal says what it holds") {
        assertEqual(P.revealTitle(isShown: false), "Transcript")
        assertEqual(P.revealTitle(isShown: true), "Hide transcript")
        assertEqual(P.lineCountText(214), "214 lines")
        assertEqual(P.lineCountText(1), "1 line")
        assertNil(P.lineCountText(nil), "no count until the file is read")
        assertEqual(P.showAllTitle(totalLineCount: 214), "Show all 214 lines")
        assertNil(P.showAllTitle(totalLineCount: P.openedLineLimit), "a transcript that fits shows whole")
        assertEqual(P.shownLineCount(total: 214, showsAll: false), 60)
        assertEqual(P.shownLineCount(total: 214, showsAll: true), 214)
        assertEqual(P.shownLineCount(total: 12, showsAll: false), 12)
    }

    runSuite("A row reads to VoiceOver as title, day and time, length") {
        assertEqual(
            P.accessibilityLabel(title: "Pricing page review", dayHeader: "Today", time: "2:00 PM",
                                 start: start, end: start.addingTimeInterval(48 * 60)),
            "Pricing page review, today 2:00 PM, 48 minutes"
        )
        assertEqual(
            P.accessibilityLabel(title: "Call with the accountant", dayHeader: "Monday, Nov 16", time: "9:30 AM",
                                 start: nil, end: nil),
            "Call with the accountant, Monday, Nov 16 9:30 AM"
        )
        assertEqual(P.spokenDuration(start: start, end: start.addingTimeInterval(61 * 60)), "1 hour 1 minute")
        assertEqual(P.spokenDuration(start: start, end: start.addingTimeInterval(120 * 60)), "2 hours")
        assertEqual(P.spokenDuration(start: start, end: start.addingTimeInterval(20)), "less than a minute")
    }

    runSuite("The titles opt-in line follows the titles controller wherever it was turned on") {
        typealias Line = MeetingTitlesOptInLine
        func state(
            enabled: Bool = false,
            status: MeetingTitlesController.ModelStatus = .notDownloaded,
            dismissed: Bool = false,
            automated: Bool = false,
            hasMeetings: Bool = true
        ) -> Line.State {
            Line.state(isEnabled: enabled, status: status, dismissed: dismissed,
                       isAutomatedLaunch: automated, hasMeetings: hasMeetings)
        }
        assertEqual(Line.offer, "Get titles and summaries \u{00B7} 3.1 GB download")
        assertEqual(state(), .offer("Get titles and summaries \u{00B7} 3.1 GB download"), "off: offer it with its size")
        assertEqual(state(status: .ready), .offer("Get titles and summaries"),
                    "off with the model already on disk: nothing to download, so no size")
        assertEqual(state(dismissed: true), .hidden, "dismissed for good")
        assertEqual(state(automated: true), .hidden, "never during automated launches")
        assertEqual(state(hasMeetings: false), .hidden, "an empty library has its own first-run words")
        if case .downloading(let fraction, let text) = state(enabled: true, status: .downloading(received: 50, total: 200)) {
            assertEqual(fraction, 0.25)
            assertTrue(text.hasPrefix("Downloading "), "says it is downloading")
        } else {
            assertTrue(false, "on and downloading: the line shows the download, wherever it was turned on")
        }
        assertEqual(state(enabled: true, status: .notDownloaded), .downloading(fraction: 0, text: "Starting download\u{2026}"))
        assertEqual(state(enabled: true, status: .failed(.offline)), .failed("Download stopped"),
                    "a failure shows here too, not only in Settings")
        assertEqual(state(enabled: true, status: .ready), .hidden, "ready: it goes")
        assertEqual(state(enabled: true, status: .downloading(received: 1, total: 4), dismissed: true), .hidden,
                    "a dismissed line stays gone; Settings still shows the download")
    }

    runSuite("Who spoke? in the opened card's menu only opens when there is a card") {
        typealias W = P.WhoSpokeAvailability
        assertEqual(P.whoSpokeAvailability(isOpen: false, hasQueuedReview: false, transcript: .notLoaded), W.hidden,
                    "a closed row with nothing waiting doesn't offer it")
        assertEqual(P.whoSpokeAvailability(isOpen: false, hasQueuedReview: true, transcript: .notLoaded), W.enabled,
                    "voices waiting in review: their card")
        assertEqual(P.whoSpokeAvailability(isOpen: true, hasQueuedReview: false, transcript: .notLoaded), W.disabled,
                    "greyed while the opened card's lines load")
        assertEqual(P.whoSpokeAvailability(isOpen: true, hasQueuedReview: false, transcript: .failed), W.disabled)
        assertEqual(P.whoSpokeAvailability(isOpen: true, hasQueuedReview: false, transcript: .loaded(speakerLineCount: 0)), W.disabled,
                    "a transcript with no speaker lines has nobody to name")
        assertEqual(P.whoSpokeAvailability(isOpen: true, hasQueuedReview: false, transcript: .loaded(speakerLineCount: 214)), W.enabled,
                    "loaded lines: the card built from the transcript")
        assertEqual(P.whoSpokeAvailability(isOpen: true, hasQueuedReview: true, transcript: .notLoaded), W.enabled)
    }

    runSuite("A failed row reads as one button with Try again as a named action") {
        let slot = P.Slot.problem("Not transcribed", actionTitle: "Try again")
        let ready = P.failedRowAccessibility(title: "Weekly sync", dayHeader: "Today", time: "10:00 AM", slot: slot, retryIsEnabled: true)
        assertEqual(ready.label, "Weekly sync, today 10:00 AM")
        assertEqual(ready.value, "Not transcribed")
        assertEqual(ready.actionNames, ["Try again"], "VoiceOver reaches Try again from the row")
        let blocked = P.failedRowAccessibility(title: "Weekly sync", dayHeader: "Monday, Nov 16", time: "10:00 AM", slot: slot, retryIsEnabled: false)
        assertEqual(blocked.actionNames, [], "no action while a retry can't start")
        assertEqual(blocked.label, "Weekly sync, Monday, Nov 16 10:00 AM")
        let retrying = P.failedRowAccessibility(title: "Weekly sync", dayHeader: "Today", time: "10:00 AM",
                                                slot: .working("Retrying", percent: nil), retryIsEnabled: true)
        assertEqual(retrying.value, "Retrying")
        assertEqual(retrying.actionNames, [])
        let missing = P.failedRowAccessibility(title: "Weekly sync", dayHeader: "Today", time: "10:00 AM",
                                               slot: .problem("Audio missing", actionTitle: nil), retryIsEnabled: true)
        assertEqual(missing.actionNames, [], "nothing to retry without audio")
    }

    runSuite("The scrubber hides its times until the length is known") {
        assertNil(P.scrubberClockTexts(fraction: 0, total: 0), "never 0:00 / 0:00")
        let known = P.scrubberClockTexts(fraction: 0.5, total: 96)
        assertEqual(known?.elapsed, "0:48")
        assertEqual(known?.total, "1:36")
        assertEqual(P.scrubberClockTexts(fraction: 2, total: 60)?.elapsed, "1:00", "a drag past the end stops at the end")
    }

    runSuite("The open card re-reads its transcript when that file changes") {
        let open = URL(fileURLWithPath: "/tmp/fictional/Pricing page review.md")
        assertTrue(P.shouldRereadOpenCard(openTranscriptURL: open, affectedIDs: [open.standardizedFileURL.path]))
        assertTrue(P.shouldRereadOpenCard(openTranscriptURL: open, affectedIDs: []), "a library-wide change includes it")
        assertFalse(P.shouldRereadOpenCard(openTranscriptURL: open, affectedIDs: ["/tmp/fictional/Weekly sync.md"]))
        assertFalse(P.shouldRereadOpenCard(openTranscriptURL: nil, affectedIDs: []), "nothing open, nothing to read")
    }

    runSuite("Search finds a meeting by its line and summary, not just its title") {
        var item = RecentMeetingItem(
            title: "Meeting at 2:00 PM", date: start, startDate: nil, endDate: nil,
            transcriptURL: URL(fileURLWithPath: "/tmp/fictional-meeting.md"), audio: nil, speakerStatus: .ready
        )
        item.titles = MeetingTitlesFields(
            aiTitle: "Pricing page review", aiTitleReplaces: "Meeting at 2:00 PM",
            line: "Team tier comes off the page.", summary: "Walked through the new pricing page with Marcus."
        )
        let haystack = HomeMeetingListFilter.haystack(for: HomeMeetingListFilter.searchFields(for: item))
        for query in ["pricing review", "team tier", "walked marcus", "2:00"] {
            assertTrue(
                HomeMeetingListFilter.matches(tokens: HomeMeetingListFilter.tokens(in: query), haystack: haystack),
                "\(query) finds it"
            )
        }
        assertFalse(HomeMeetingListFilter.matches(tokens: ["northwind"], haystack: haystack))
    }

    runSuite("Line times show as a plain clock") {
        assertEqual(MeetingAudioPlayback.clockText(19), "0:19")
        assertEqual(MeetingAudioPlayback.clockText(32 * 60 + 10), "32:10")
        assertEqual(MeetingAudioPlayback.clockText(3723), "1:02:03")
    }

    runSuite("Unnamed voices are spotted so subtitles don't list them as people") {
        for name in ["Speaker", "Speaker 2", "speaker 12", "Unknown"] {
            assertTrue(P.isUnnamedVoice(name), "\(name) is a voice nobody named yet")
        }
        for name in ["You", "Priya", "Speaker Lee", "Speakerphone"] {
            assertFalse(P.isUnnamedVoice(name), "\(name) is a name")
        }
    }

    runSuite("The audio source picker says you and others, not devices") {
        assertEqual(MeetingAudioSourceTitle.title(sourceStem: "microphone", fallback: "Mic"), "You")
        assertEqual(MeetingAudioSourceTitle.title(sourceStem: "system_audio", fallback: "System"), "Others")
        assertEqual(MeetingAudioSourceTitle.title(sourceStem: "playback", fallback: "Mix"), "Mix")
    }
}
