import Foundation

func testMeetingArmedPromptCopy() {
    let start = Date(timeIntervalSince1970: 1_000_000)

    runSuite("MeetingArmedPromptCopy — pre-arm shows a rounded-up minutes countdown") {
        // 60s ahead → "Starts in 1 min" (the default lead), and the card is in
        // the silent pre-arm phase, not chiming.
        let copy = MeetingArmedPromptCopyPolicy.make(
            eventTitle: "Weekly 1:1 with Sarah",
            startDate: start,
            now: start.addingTimeInterval(-60),
            showRealTitles: true,
            isScreenShareLikely: false
        )
        assertEqual(copy.phase, .preArm, "a meeting still ahead should be in the pre-arm phase")
        assertEqual(copy.subtext, "Starts in 1 min", "a 60s lead should read 'Starts in 1 min'")
        assertEqual(copy.title, "Weekly 1:1 with Sarah", "pre-arm should show the resolved event title")
        assertFalse(copy.shouldChimeOnStartNudge, "the silent pre-arm card must not chime")
    }

    runSuite("MeetingArmedPromptCopy — minutes round up so a short lead never reads 0 min") {
        assertEqual(
            MeetingArmedPromptCopyPolicy.subtext(secondsUntilStart: 40),
            "Starts in 1 min",
            "a 40s lead should round up to 1 min, never 'Starts in 0 min'"
        )
        assertEqual(
            MeetingArmedPromptCopyPolicy.subtext(secondsUntilStart: 61),
            "Starts in 2 min",
            "just over a minute should read 'Starts in 2 min'"
        )
        assertEqual(
            MeetingArmedPromptCopyPolicy.subtext(secondsUntilStart: 150),
            "Starts in 3 min",
            "150s should round up to 3 min"
        )
    }

    runSuite("MeetingArmedPromptCopy — at start it flips to the single gentle nudge and chimes") {
        let copy = MeetingArmedPromptCopyPolicy.make(
            eventTitle: "Weekly 1:1 with Sarah",
            startDate: start,
            now: start,
            showRealTitles: true,
            isScreenShareLikely: false
        )
        assertEqual(copy.phase, .startingNow, "reaching the start time should enter the starting-now phase")
        assertEqual(
            copy.subtext,
            "Starting now — tap to record",
            "the T-0 nudge should be the single starting-now line"
        )
        assertTrue(copy.shouldChimeOnStartNudge, "the starting-now nudge fires the one soft chime")
    }

    runSuite("MeetingArmedPromptCopy — a meeting already underway stays in the starting-now nudge") {
        let copy = MeetingArmedPromptCopyPolicy.make(
            eventTitle: "Standup",
            startDate: start,
            now: start.addingTimeInterval(90),
            showRealTitles: true,
            isScreenShareLikely: false
        )
        assertEqual(copy.phase, .startingNow, "a meeting past its start time should stay in the nudge phase")
        assertEqual(copy.subtext, "Starting now — tap to record", "the nudge copy should not regress to a countdown")
    }

    runSuite("MeetingArmedPromptCopy — opting out of real titles shows the generic label") {
        let title = MeetingArmedPromptCopyPolicy.displayTitle(
            eventTitle: "Board comp review",
            showRealTitles: false,
            isScreenShareLikely: false
        )
        assertEqual(title, "Meeting", "the privacy opt-out should hide the event title behind a generic label")
    }

    runSuite("MeetingArmedPromptCopy — a screen-share forces the generic label even with real titles on") {
        let title = MeetingArmedPromptCopyPolicy.displayTitle(
            eventTitle: "Board comp review",
            showRealTitles: true,
            isScreenShareLikely: true
        )
        assertEqual(
            title,
            "Meeting",
            "a detected screen-share should default to the generic label regardless of the toggle (shoulder-surf safety)"
        )
    }

    runSuite("MeetingArmedPromptCopy — a blank event title falls back to the generic label") {
        let title = MeetingArmedPromptCopyPolicy.displayTitle(
            eventTitle: "   ",
            showRealTitles: true,
            isScreenShareLikely: false
        )
        assertEqual(title, "Meeting", "an empty or whitespace-only title should fall back to the generic label")
    }
}
