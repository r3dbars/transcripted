// The Meetings page (QuietMeetingCard and its rows): day headers, what fills
// a closed row's summary slot, the opened card's subtitle and menu, one open
// row at a time with its transcript closed on open, and when the titles
// opt-in line shows (HomeMeetingCardPresentation). Fictional names only.

import Foundation

func testHomeMeetingCard() {
    let start = Date(timeIntervalSinceReferenceDate: 800_000_000)
    typealias P = HomeMeetingCardPresentation

    runSuite("Meetings group by day: Today, Yesterday, then the weekday and date") {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = .current
        let today = calendar.startOfDay(for: Date())
        assertEqual(P.dayHeader(for: today, calendar: calendar), "Today")
        assertEqual(P.dayHeader(for: calendar.date(byAdding: .day, value: -1, to: today)!, calendar: calendar), "Yesterday")
        let older = calendar.date(from: DateComponents(year: 2026, month: 11, day: 16))!
        let expected = HomeDaySectionLabel.formatter.string(from: older)
        assertEqual(P.dayHeader(for: older, calendar: calendar), expected)
        assertEqual(HomeDaySectionLabel.formatter.dateFormat, "EEEE, MMM d", "older days read like Monday, Nov 16")
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

    runSuite("The titles opt-in line shows only while it has something to offer") {
        typealias Line = MeetingTitlesOptInLine
        func state(
            enabled: Bool = false,
            status: MeetingTitlesController.ModelStatus = .notDownloaded,
            dismissed: Bool = false,
            automated: Bool = false,
            hasMeetings: Bool = true,
            startedHere: Bool = false
        ) -> Line.State {
            Line.state(isEnabled: enabled, status: status, dismissed: dismissed,
                       isAutomatedLaunch: automated, hasMeetings: hasMeetings, startedHere: startedHere)
        }
        assertEqual(Line.offer, "Get titles and summaries \u{00B7} 3.1 GB download")
        assertEqual(state(), .offer, "off: offer it")
        assertEqual(state(dismissed: true), .hidden, "dismissed for good")
        assertEqual(state(automated: true), .hidden, "never during automated launches")
        assertEqual(state(hasMeetings: false), .hidden, "an empty library has its own first-run words")
        assertEqual(state(enabled: true, status: .downloading(received: 1, total: 4)), .hidden,
                    "turned on in Settings: the Settings row shows the download, not this line")
        if case .downloading(let fraction, let text) = state(
            enabled: true, status: .downloading(received: 50, total: 200), startedHere: true
        ) {
            assertEqual(fraction, 0.25)
            assertTrue(text.hasPrefix("Downloading "), "says it is downloading")
        } else {
            assertTrue(false, "turned on here: the line shows the download")
        }
        assertEqual(state(enabled: true, status: .failed(.offline), startedHere: true), .failed("Download stopped"))
        assertEqual(state(enabled: true, status: .ready, startedHere: true), .hidden, "ready: it goes")
        assertEqual(state(enabled: true, status: .ready, dismissed: true, automated: true, startedHere: true), .hidden)
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
