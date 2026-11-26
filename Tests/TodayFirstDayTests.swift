import Foundation

// Promises: the empty state names the person's own dictation key and how
// it behaves; the setup checklist shows only what's left and retires for
// good; a dictation click knows which saved entry to land on.
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
            triedFileImport: false, dismissed: false, offered: true
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

    runSuite("Only people who finish setup on a build with the checklist see it") {
        let suiteName = "TodayFirstDayTests.offered.\(UUID().uuidString)"
        guard let defaults = UserDefaults(suiteName: suiteName) else {
            assertTrue(false, "test defaults suite")
            return
        }
        defer { defaults.removePersistentDomain(forName: suiteName) }
        // Someone who set up on an older build: completion saved, no new flag.
        defaults.set(true, forKey: PermissionsOnboardingPreferences.completionKey)
        assertFalse(TodaySetupChecklistPreferences.isOffered(userDefaults: defaults),
                    "an update doesn't offer the checklist to someone already set up")
        let existing = TodaySetupChecklistState(
            calendarConnected: false, calendarBlocked: false, agentConnected: false,
            triedFileImport: false, dismissed: false,
            offered: TodaySetupChecklistPreferences.isOffered(userDefaults: defaults)
        )
        assertFalse(existing.isShown, "steps left, but never offered, so it stays hidden")
        PermissionsOnboardingPreferences.markCompleted(userDefaults: defaults)
        assertTrue(TodaySetupChecklistPreferences.isOffered(userDefaults: defaults),
                   "finishing setup on this build offers it")
        var fresh = existing
        fresh.offered = true
        assertTrue(fresh.isShown)
    }

    runSuite("A file imported any way counts as the file step") {
        let suiteName = "TodayFirstDayTests.import.\(UUID().uuidString)"
        guard let defaults = UserDefaults(suiteName: suiteName) else {
            assertTrue(false, "test defaults suite")
            return
        }
        defer { defaults.removePersistentDomain(forName: suiteName) }
        TodaySetupChecklistPreferences.noteFilesImported(count: 0, userDefaults: defaults)
        assertFalse(TodaySetupChecklistPreferences.hasTriedFileImport(userDefaults: defaults),
                    "nothing importable, nothing done")
        TodaySetupChecklistPreferences.noteFilesImported(count: 2, userDefaults: defaults)
        assertTrue(TodaySetupChecklistPreferences.hasTriedFileImport(userDefaults: defaults),
                   "a drop or ⌘O import checks the step off")
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
