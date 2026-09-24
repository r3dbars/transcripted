// MeetingPromptLearnedBackoffTests.swift
// Pins how "Not now" on the detected-call prompt is remembered: longer quiet
// for each consecutive Not now, a Record resets it, an unrecognized browser
// mic that is always turned down stops asking, and all of it survives a
// relaunch.

import Foundation

func testMeetingPromptLearnedBackoff() {
    guard #available(macOS 14.0, *) else { return }

    let unverified = MeetingPromptLearnedBackoff.unverifiedBrowserKind
    let verified = MeetingPromptLearnedBackoff.verifiedBrowserKind
    let zoom = MeetingPromptLearnedBackoff.nativeKind(for: .zoom)
    let start = Date(timeIntervalSince1970: 1_000_000)
    // Typed constants keep the literal arithmetic below cheap for the type
    // checker (untyped `8 * 60 * 60` inside a generic call timed out in CI).
    let minute: TimeInterval = 60
    let hour: TimeInterval = 60 * minute

    runSuite("MeetingPromptLearnedBackoff — each Not now stays quiet longer") {
        let backoff = MeetingPromptLearnedBackoff()
        var now = start
        var quiet: [TimeInterval] = []
        for _ in 0..<5 {
            let until = backoff.recordDismissal(kind: unverified, now: now)
            quiet.append(until.timeIntervalSince(now))
            now = until.addingTimeInterval(1)
        }
        let expected: [TimeInterval] = [30 * minute, 2 * hour, 8 * hour, 24 * hour, 24 * hour]
        assertEqual(
            quiet,
            expected,
            "an unrecognized browser mic backs off 30m, 2h, 8h, then a day"
        )
    }

    runSuite("MeetingPromptLearnedBackoff — real call kinds cap at 8 hours") {
        let backoff = MeetingPromptLearnedBackoff()
        var now = start
        var last: TimeInterval = 0
        for _ in 0..<6 {
            let until = backoff.recordDismissal(kind: zoom, now: now)
            last = until.timeIntervalSince(now)
            now = until.addingTimeInterval(1)
        }
        assertEqual(last, 8 * hour, "tomorrow's Zoom call should still get its prompt")
        for kind in [
            verified,
            MeetingPromptLearnedBackoff.callSiteBrowserKind,
            MeetingPromptLearnedBackoff.cameraBrowserKind,
        ] {
            assertEqual(
                MeetingPromptLearnedBackoff.quietInterval(forStreak: 9, kind: kind),
                8 * hour,
                "\(kind) caps like a native app"
            )
        }
    }

    runSuite("MeetingPromptLearnedBackoff — quiet window and kinds are separate") {
        let backoff = MeetingPromptLearnedBackoff()
        backoff.recordDismissal(kind: unverified, now: start)
        assertNotNil(backoff.quietUntil(for: unverified, now: start.addingTimeInterval(60)), "the kind just turned down is quiet")
        assertNil(backoff.quietUntil(for: verified, now: start.addingTimeInterval(60)), "a Not now to ChatGPT voice must not quiet a real Meet tab")
        assertNil(backoff.quietUntil(for: zoom, now: start.addingTimeInterval(60)), "nor a native app")
        assertNil(backoff.quietUntil(for: unverified, now: start.addingTimeInterval(31 * minute)), "the first quiet window ends after 30 minutes")
    }

    runSuite("MeetingPromptLearnedBackoff — Record resets the streak and the quiet") {
        let backoff = MeetingPromptLearnedBackoff()
        backoff.recordDismissal(kind: zoom, now: start)
        backoff.recordDismissal(kind: zoom, now: start.addingTimeInterval(3_600))
        backoff.recordAccepted(kind: zoom, now: start.addingTimeInterval(3_700))
        assertEqual(backoff.dismissStreak(for: zoom, now: start.addingTimeInterval(3_700)), 0, "a recording clears the streak")
        assertNil(backoff.quietUntil(for: zoom, now: start.addingTimeInterval(3_700)), "a recording clears the quiet window")
        let until = backoff.recordDismissal(kind: zoom, now: start.addingTimeInterval(4_000))
        assertEqual(until.timeIntervalSince(start.addingTimeInterval(4_000)), 30 * minute, "the next Not now starts over at 30 minutes")
    }

    runSuite("MeetingPromptLearnedBackoff — a browser mic that is always turned down stops asking") {
        let backoff = MeetingPromptLearnedBackoff()
        var now = start
        for _ in 0..<MeetingPromptLearnedBackoff.learnedOffStreak {
            assertFalse(backoff.isLearnedOff(kind: unverified, now: now), "not learned off before the streak is reached")
            now = backoff.recordDismissal(kind: unverified, now: now).addingTimeInterval(1)
        }
        assertTrue(backoff.isLearnedOff(kind: unverified, now: now), "three Not nows and no recording ever turns it off")
        assertFalse(
            backoff.isLearnedOff(kind: unverified, now: now.addingTimeInterval(MeetingPromptLearnedBackoff.streakForgetInterval + 1)),
            "the habit is forgotten after two weeks, so the prompt can come back"
        )

        let recorder = MeetingPromptLearnedBackoff()
        recorder.recordAccepted(kind: unverified, now: start)
        var later = start.addingTimeInterval(60)
        for _ in 0..<5 {
            later = recorder.recordDismissal(kind: unverified, now: later).addingTimeInterval(1)
        }
        assertFalse(recorder.isLearnedOff(kind: unverified, now: later), "someone who recorded a browser call this month is not turned off")

        let oldRecorder = MeetingPromptLearnedBackoff()
        oldRecorder.recordAccepted(kind: unverified, now: start)
        var monthLater = start.addingTimeInterval(MeetingPromptLearnedBackoff.acceptedMemoryInterval + 60)
        for _ in 0..<MeetingPromptLearnedBackoff.learnedOffStreak {
            monthLater = oldRecorder.recordDismissal(kind: unverified, now: monthLater).addingTimeInterval(1)
        }
        assertTrue(oldRecorder.isLearnedOff(kind: unverified, now: monthLater), "one recording long ago does not keep it on forever")

        let meet = MeetingPromptLearnedBackoff()
        var meetNow = start
        for _ in 0..<5 {
            meetNow = meet.recordDismissal(kind: verified, now: meetNow).addingTimeInterval(1)
        }
        assertFalse(meet.isLearnedOff(kind: verified, now: meetNow), "a named call tab is never turned off, only backed off")

        for kind in [MeetingPromptLearnedBackoff.cameraBrowserKind, MeetingPromptLearnedBackoff.callSiteBrowserKind] {
            let other = MeetingPromptLearnedBackoff()
            var otherNow = start
            for _ in 0..<5 {
                otherNow = other.recordDismissal(kind: kind, now: otherNow).addingTimeInterval(1)
            }
            assertFalse(other.isLearnedOff(kind: kind, now: otherNow), "\(kind) is never turned off, only backed off")
        }
    }

    runSuite("MeetingPromptLearnedBackoff — reset forgets everything") {
        let suiteName = "MeetingPromptLearnedBackoffTests.reset.\(UUID().uuidString)"
        guard let defaults = UserDefaults(suiteName: suiteName) else {
            assertTrue(false, "could not create an isolated defaults suite")
            return
        }
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let backoff = MeetingPromptLearnedBackoff(userDefaults: defaults)
        var now = start
        for _ in 0..<MeetingPromptLearnedBackoff.learnedOffStreak {
            now = backoff.recordDismissal(kind: unverified, now: now).addingTimeInterval(1)
        }
        assertTrue(backoff.isLearnedOff(kind: unverified, now: now), "precondition: learned off")
        backoff.reset()
        assertFalse(backoff.isLearnedOff(kind: unverified, now: now), "reset turns the prompt back on")
        assertNil(backoff.quietUntil(for: unverified, now: now), "reset clears the quiet window")
        assertEqual(
            MeetingPromptLearnedBackoff(userDefaults: defaults).dismissStreak(for: unverified, now: now),
            0,
            "reset also clears what was saved for the next launch"
        )
    }

    runSuite("MeetingPromptLearnedBackoff — survives a relaunch") {
        let suiteName = "MeetingPromptLearnedBackoffTests.\(UUID().uuidString)"
        guard let defaults = UserDefaults(suiteName: suiteName) else {
            assertTrue(false, "could not create an isolated defaults suite")
            return
        }
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let first = MeetingPromptLearnedBackoff(userDefaults: defaults)
        first.recordDismissal(kind: unverified, now: start)
        first.recordDismissal(kind: unverified, now: start.addingTimeInterval(31 * minute))

        let relaunched = MeetingPromptLearnedBackoff(userDefaults: defaults)
        assertEqual(relaunched.dismissStreak(for: unverified, now: start.addingTimeInterval(32 * minute)), 2, "the streak comes back after a relaunch")
        assertNotNil(relaunched.quietUntil(for: unverified, now: start.addingTimeInterval(hour)), "the quiet window comes back after a relaunch")

        let memoryOnly = MeetingPromptLearnedBackoff()
        assertEqual(memoryOnly.dismissStreak(for: unverified, now: start), 0, "a store without defaults starts empty and never touches disk")
    }
}
