// DictationSessionTimeoutTests.swift
// Tests for uptime-based dictation timeout tracking.

import Foundation

func testDictationSessionTimeout() {
    runSuite("DictationSessionTimeout.start — sets a deadline from active uptime") {
        var timeout = DictationSessionTimeout(timeoutInterval: 300)
        timeout.start(at: 1_000)

        assertEqual(timeout.deadlineUptime, 1_300, "deadline should be offset by timeout interval")
        assertEqual(timeout.remaining(at: 1_120), 180, "remaining time should shrink with uptime")
        assertFalse(timeout.isExpired(at: 1_299), "timeout should not expire before deadline")
        assertTrue(timeout.isExpired(at: 1_300), "timeout should expire at deadline")
    }

    runSuite("DictationSessionTimeout.remaining — does not burn time while uptime is paused") {
        var timeout = DictationSessionTimeout(timeoutInterval: 300)
        timeout.start(at: 10_000)

        let beforeSleep = timeout.remaining(at: 10_030)
        let afterWake = timeout.remaining(at: 10_031)

        assertEqual(beforeSleep, 270, "active uptime should leave 270 seconds after 30 seconds")
        assertEqual(afterWake, 269, "only active uptime should reduce the remaining timeout budget")
    }

    runSuite("DictationSessionTimeout.clear — resets timeout state") {
        var timeout = DictationSessionTimeout(timeoutInterval: 300)
        timeout.start(at: 42)
        timeout.clear()

        assertNil(timeout.deadlineUptime, "clearing should discard the deadline")
        assertNil(timeout.remaining(at: 50), "remaining time should be nil once cleared")
        assertFalse(timeout.isExpired(at: 999), "cleared timeout should not report expired")
    }
}
