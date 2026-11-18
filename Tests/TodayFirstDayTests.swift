import Foundation

// Promises: Today's first day names the person's own dictation key and how
// it behaves; the setup checklist shows only what's left and retires for
// good; a live meeting sits on today's lane from its start to now; a Today
// dictation click knows which saved entry to land on.
func testTodayFirstDay() {
    runSuite("The first-day key line uses the configured key and behavior") {
        let hold = TodayKeyHint.make(keyDisplay: "Right ⌥", behavior: .holdOrTap)
        assertEqual(hold.text, "Hold Right ⌥ in any app and talk. Let go to paste.", "hold or tap teaches the hold")
        assertEqual(TodayKeyHint.make(keyDisplay: "Right ⌥", behavior: .holdOnly).text,
                    "Hold Right ⌥ in any app and talk. Let go to paste.", "hold only reads the same")
        assertEqual(TodayKeyHint.make(keyDisplay: "Fn", behavior: .tapToToggle).text,
                    "Tap Fn in any app and talk. Tap again to paste.", "tap to toggle names the tap and the key")
        let off = TodayKeyHint.make(keyDisplay: nil, behavior: .holdOrTap)
        assertNil(off.key, "with shortcuts off there is no key to show")
        assertTrue(off.text.contains("menu bar"), "with shortcuts off it points at the menu bar")
    }

    runSuite("The setup checklist shows what's left and hides once done or dismissed") {
        var state = TodaySetupChecklistState(
            calendarConnected: false, calendarBlocked: false, agentConnected: nil,
            triedFileImport: false, dismissed: false
        )
        assertEqual(state.remaining, [.calendar, .transcribeFile], "the agent row waits for its check")
        assertTrue(state.isShown, "a fresh install sees it")
        state.agentConnected = false
        assertEqual(state.remaining, [.calendar, .agent, .transcribeFile], "all three once the check says no agent")
        state.calendarConnected = true
        state.triedFileImport = true
        assertEqual(state.remaining, [.agent], "done steps drop out")
        state.agentConnected = true
        assertTrue(state.isComplete, "every step done")
        assertFalse(state.isShown, "a complete list hides")
        state.calendarConnected = false
        state.dismissed = true
        assertFalse(state.isShown, "a dismissed list never shows, even with steps left")
        assertTrue(TodaySetupStep.calendar.detail(calendarBlocked: true).contains("System Settings"),
                   "a blocked calendar says where to turn it on")
    }

    runSuite("Checklist preferences persist in the suite they're given") {
        let suiteName = "TodayFirstDayTests.\(UUID().uuidString)"
        guard let defaults = UserDefaults(suiteName: suiteName) else {
            assertTrue(false, "test defaults suite")
            return
        }
        defer { defaults.removePersistentDomain(forName: suiteName) }
        assertFalse(TodaySetupChecklistPreferences.isDismissed(userDefaults: defaults), "not dismissed by default")
        assertFalse(TodaySetupChecklistPreferences.hasTriedFileImport(userDefaults: defaults), "no import tried by default")
        TodaySetupChecklistPreferences.markTriedFileImport(userDefaults: defaults)
        TodaySetupChecklistPreferences.retire(userDefaults: defaults)
        assertTrue(TodaySetupChecklistPreferences.hasTriedFileImport(userDefaults: defaults), "a tried import is remembered")
        assertTrue(TodaySetupChecklistPreferences.isDismissed(userDefaults: defaults), "retiring is remembered")
    }

    runSuite("A live meeting spans its start to now on today's lane") {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "America/Los_Angeles")!
        let now = calendar.date(from: DateComponents(year: 2026, month: 9, day: 24, hour: 15))!
        let today = calendar.startOfDay(for: now)
        guard let span = TodayLiveMeetingSpan.make(elapsedSeconds: 18 * 60, now: now, tapeDay: today, calendar: calendar) else {
            assertTrue(false, "today's lane should get a live span")
            return
        }
        // The window is 6 AM to midnight: 18 hours.
        assertEqual(span.end, 9.0 / 18.0, "the bar ends at now")
        assertEqual(span.start, 31_320.0 / 64_800.0, "the bar starts when the recording did")
        let yesterday = calendar.date(byAdding: .day, value: -1, to: today)!
        assertNil(TodayLiveMeetingSpan.make(elapsedSeconds: 60, now: now, tapeDay: yesterday, calendar: calendar),
                  "a past day never shows a live bar")
        let early = TodayLiveMeetingSpan.make(elapsedSeconds: 20 * 3600, now: now, tapeDay: today, calendar: calendar)
        assertEqual(early?.start, 0, "a recording older than the window starts at the left edge")
    }

    runSuite("A Today dictation row knows its saved entry") {
        let dictation = TodayRecentItem(kind: .dictation, id: TodayRecentItem.dictationIDPrefix + "file.md#3",
                                        title: "A note", date: Date(), durationSeconds: nil, transcriptURL: nil)
        assertEqual(dictation.dictationEntryID, "file.md#3", "the entry id comes back whole")
        let meeting = TodayRecentItem(kind: .meeting, id: "meeting-1", title: "Weekly sync", date: Date(),
                                      durationSeconds: 60, transcriptURL: nil)
        assertNil(meeting.dictationEntryID, "a meeting has no dictation entry")
    }
}
