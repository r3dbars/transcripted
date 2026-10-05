import Foundation

// Behavioral coverage for the Writing tab's refresh timers
// (Sources/Writing/WritingRefreshTimers.swift): a closed Settings window
// suspends them, and showing it again resumes exactly one pair.

@MainActor
func testWritingRefreshTimers() {
    runSuite("Only saves to the displayed Writing day invalidate its preview") {
        let today = URL(fileURLWithPath: "/tmp/writing-fixture/Writing_2026-10-05.md")
        let old = URL(fileURLWithPath: "/tmp/writing-fixture/Writing_2026-10-04.md")
        assertTrue(WritingDayRefreshPolicy.shouldReload(savedURL: today, todayURL: today))
        assertFalse(WritingDayRefreshPolicy.shouldReload(savedURL: old, todayURL: today), "old-day rescrubs do not reread today")
        assertTrue(WritingDayRefreshPolicy.shouldReload(savedURL: nil, todayURL: today), "unknown producers retain conservative refresh")
        assertTrue(WritingDayRefreshPolicy.shouldReload(savedURL: old, todayURL: old), "the day is supplied at notification time, including midnight")
    }

    runSuite("Writing refresh timers suspend and resume as one pair") {
        let timers = WritingRefreshTimers(liveInterval: 1, statsInterval: 5)
        assertFalse(timers.isRunning, "nothing runs before the page arms them")

        assertTrue(timers.resume(live: {}, stats: {}), "the first resume arms the pair")
        let live = timers.liveTimer
        let stats = timers.statsTimer
        assertTrue(live?.isValid == true, "the live timer runs")
        assertTrue(stats?.isValid == true, "the stats timer runs")
        assertEqual(live?.timeInterval, 1, "the live refresh keeps its 1 s interval")
        assertEqual(stats?.timeInterval, 5, "the stats refresh keeps its 5 s interval")
        assertTrue((live?.tolerance ?? 0) > 0, "the live timer lets the system coalesce wakeups")
        assertTrue((stats?.tolerance ?? 0) > 0, "the stats timer lets the system coalesce wakeups")

        assertFalse(timers.resume(live: {}, stats: {}), "a second resume is a no-op")
        assertTrue(timers.liveTimer === live, "a second resume keeps the same live timer")
        assertTrue(timers.statsTimer === stats, "a second resume keeps the same stats timer")

        timers.suspend()
        assertFalse(timers.isRunning, "a closed window leaves no timer")
        assertFalse(live?.isValid ?? true, "the suspended live timer no longer fires")
        assertFalse(stats?.isValid ?? true, "the suspended stats timer no longer fires")
        timers.suspend()
        assertFalse(timers.isRunning, "suspending twice is harmless")

        assertTrue(timers.resume(live: {}, stats: {}), "showing the window again re-arms")
        assertTrue(timers.liveTimer !== live, "the resumed pair is new")
        assertTrue(timers.isRunning)
        timers.suspend()
    }
}
