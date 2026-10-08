import Foundation

/// The per-session crash-free rate only means something if a session covers a
/// stretch of use, not a multi-day menu bar run.
func testSentrySessionRotationPolicy() {
    let start = Date(timeIntervalSinceReferenceDate: 1_000_000)
    let day = SentrySessionRotationPolicy.maxSessionAge

    runSuite("sleep ends the open session and wake starts a new one") {
        assertEqual(
            SentrySessionRotationPolicy.action(for: .willSleep, sessionStartedAt: start, wantsSession: true, now: start),
            .end,
            "the Mac going to sleep closes the session"
        )
        assertEqual(
            SentrySessionRotationPolicy.action(for: .didWake, sessionStartedAt: nil, wantsSession: true, now: start),
            .start,
            "waking starts a fresh session"
        )
        assertEqual(
            SentrySessionRotationPolicy.action(for: .didWake, sessionStartedAt: start, wantsSession: true, now: start),
            .restart,
            "a wake without a sleep notice still splits the session"
        )
        assertEqual(
            SentrySessionRotationPolicy.action(for: .willSleep, sessionStartedAt: nil, wantsSession: true, now: start),
            .none,
            "sleep with no open session does nothing"
        )
    }

    runSuite("a session open for a day is restarted") {
        assertEqual(
            SentrySessionRotationPolicy.action(
                for: .periodicCheck, sessionStartedAt: start, wantsSession: true, now: start.addingTimeInterval(day - 1)
            ),
            .none,
            "a session younger than a day stays open"
        )
        assertEqual(
            SentrySessionRotationPolicy.action(
                for: .periodicCheck, sessionStartedAt: start, wantsSession: true, now: start.addingTimeInterval(day)
            ),
            .restart,
            "a day-old session is closed and a new one started"
        )
        assertEqual(
            SentrySessionRotationPolicy.action(for: .periodicCheck, sessionStartedAt: nil, wantsSession: true, now: start),
            .none,
            "the check never opens a session on its own"
        )
    }

    runSuite("no session opens without the crash-reporting choice") {
        assertEqual(
            SentrySessionRotationPolicy.action(for: .didWake, sessionStartedAt: nil, wantsSession: false, now: start),
            .none,
            "waking before onboarding or with crash reporting off starts nothing"
        )
        assertEqual(
            SentrySessionRotationPolicy.action(for: .didWake, sessionStartedAt: start, wantsSession: false, now: start),
            .end,
            "a session left open after opting out is closed on wake"
        )
        assertEqual(
            SentrySessionRotationPolicy.action(
                for: .periodicCheck, sessionStartedAt: start, wantsSession: false, now: start.addingTimeInterval(day)
            ),
            .end,
            "an opted-out session is closed, not restarted"
        )
    }
}
