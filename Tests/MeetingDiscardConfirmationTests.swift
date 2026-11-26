import Foundation

// "Discard this recording?" on the island must be exactly as safe as the
// modal alert it replaced: two deliberate clicks, and Keep, Escape, a
// timeout or anything stale keeps the recording.
func testMeetingDiscardConfirmation() {
    runSuite("Discard takes two clicks: the first only asks") {
        let id = UUID()
        var policy = MeetingDiscardConfirmPolicy()
        assertFalse(policy.isAsking(about: id))
        assertEqual(policy.handle(.confirm(recordingID: id, now: 100)), .none, "a confirm nobody was asked for does nothing")
        assertEqual(policy.handle(.request(recordingID: id, now: 100)), .ask, "the first click puts the question up")
        assertTrue(policy.isAsking(about: id))
        assertEqual(policy.handle(.confirm(recordingID: id, now: 101)), .discard(id), "the red Discard is the second click")
        assertFalse(policy.isAsking(about: id), "and the question is gone")
        assertEqual(policy.handle(.confirm(recordingID: id, now: 102)), .none, "a third click can't discard again")
    }

    runSuite("A double-click on the first Discard can't answer the question") {
        let id = UUID()
        var policy = MeetingDiscardConfirmPolicy()
        _ = policy.handle(.request(recordingID: id, now: 50))
        let tooSoon = 50 + MeetingDiscardConfirmPolicy.armDelaySeconds / 2
        assertEqual(policy.handle(.confirm(recordingID: id, now: tooSoon)), .none, "a press right after it appeared is ignored")
        assertTrue(policy.isAsking(about: id), "and the question stays up")
        let armed = 50 + MeetingDiscardConfirmPolicy.armDelaySeconds
        assertEqual(policy.handle(.confirm(recordingID: id, now: armed)), .discard(id), "a deliberate press after a beat works")
    }

    runSuite("Keep, Escape and the timeout all keep the recording") {
        let id = UUID()
        var kept = MeetingDiscardConfirmPolicy()
        _ = kept.handle(.request(recordingID: id, now: 0))
        assertEqual(kept.handle(.keep), .keep, "Keep (and Escape, which sends the same) keeps it")
        assertEqual(kept.handle(.confirm(recordingID: id, now: 5)), .none, "a late Discard after Keep does nothing")

        var timedOut = MeetingDiscardConfirmPolicy()
        _ = timedOut.handle(.request(recordingID: id, now: 0))
        assertEqual(timedOut.handle(.timedOut(recordingID: id)), .keep, "running out of time keeps it, never discards")
        assertEqual(timedOut.handle(.confirm(recordingID: id, now: 20)), .none, "and nothing is left to confirm")

        var idle = MeetingDiscardConfirmPolicy()
        assertEqual(idle.handle(.keep), .none, "Escape with no question changes nothing")
        assertEqual(idle.handle(.timedOut(recordingID: id)), .none)
    }

    runSuite("An answer for another recording never discards this one") {
        let asked = UUID()
        let other = UUID()
        var policy = MeetingDiscardConfirmPolicy()
        _ = policy.handle(.request(recordingID: asked, now: 0))
        assertEqual(policy.handle(.confirm(recordingID: other, now: 5)), .none, "a stale button from another recording")
        assertTrue(policy.isAsking(about: asked), "still asking about the right one")
        assertFalse(policy.isAsking(about: other))
        assertFalse(policy.isAsking(about: nil), "no recording, no question")
        assertEqual(policy.handle(.timedOut(recordingID: other)), .none, "another recording's timer doesn't close it")
        assertTrue(policy.isAsking(about: asked))
    }

    runSuite("Asking again doesn't skip the wait") {
        let id = UUID()
        var policy = MeetingDiscardConfirmPolicy()
        assertEqual(policy.handle(.request(recordingID: id, now: 0)), .ask)
        assertEqual(policy.handle(.request(recordingID: id, now: 3)), .none, "a second request while asking changes nothing")
        assertEqual(policy.pending?.askedAt, 0)
    }

    runSuite("The question is on the island while the recording runs, and only then") {
        let id = UUID()
        var meeting = NotchIslandMeetingContent(phase: .recording, duration: 30)
        meeting.recordingID = id
        meeting.discardConfirmSecondsLeft = 7
        let layout = NotchIslandPresentation.layout(dictation: nil, meeting: meeting, callPrompt: nil, recentInsert: nil, expanded: false)
        assertEqual(layout.drop, .meetingPrompt(MeetingDiscardConfirmCopy.prompt(recordingID: id, secondsLeft: 7)),
                    "it opens the drop-down by itself, without bringing Transcripted to the front")
        assertTrue(layout.dropIsSticky)

        var withWarning = meeting
        withWarning.duration = 1
        withWarning.prompt = NotchIslandMeetingContent.Prompt(
            title: "No sound", detail: "Nothing heard for 3 minutes.", countdown: "",
            primaryTitle: "Stop", secondaryTitle: "Dismiss", tertiaryTitle: nil
        )
        assertEqual(
            NotchIslandPresentation.layout(dictation: nil, meeting: withWarning, callPrompt: nil, recentInsert: nil, expanded: false).drop,
            .meetingPrompt(MeetingDiscardConfirmCopy.prompt(recordingID: id, secondsLeft: 7)),
            "mid-answer, the question beats a warning"
        )

        var stopped = meeting
        stopped.phase = .transcribing(progress: nil, detail: "")
        let after = NotchIslandPresentation.layout(dictation: nil, meeting: stopped, callPrompt: nil, recentInsert: nil, expanded: false)
        assertNil(after.drop, "once the recording stops there's nothing to discard, so no question")

        let dictation = NotchIslandDictationContent(phase: .listening)
        assertFalse(
            NotchIslandPresentation.layout(dictation: dictation, meeting: meeting, callPrompt: nil, recentInsert: nil, expanded: false).drop
                == .meetingPrompt(MeetingDiscardConfirmCopy.prompt(recordingID: id, secondsLeft: 7)),
            "a dictation covers it; its timeout then keeps the recording"
        )

        let key = NotchIslandPresentation.stickyKey(dictation: nil, meeting: meeting, callPrompt: nil)
        var ticked = meeting
        ticked.discardConfirmSecondsLeft = 6
        assertEqual(NotchIslandPresentation.stickyKey(dictation: nil, meeting: ticked, callPrompt: nil), key,
                    "a ticking question is the same question")
    }

    runSuite("The right-click item keeps its automation title in sentence case") {
        assertEqual(MeetingDiscardConfirmCopy.menuTitle, "Discard recording…")
    }
}
