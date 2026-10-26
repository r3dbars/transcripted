import Foundation

/// A hand-off take (Write for Me's voice) gives its words back instead of pasting, never touches the
/// person's own dictation, and finishes quietly.
@MainActor
func testDictationHandOff() async {
    runSuite("A hand-off take never starts over the person's own dictation") {
        assertTrue(DictationHandOffPolicy.mayStart(isDictating: false), "nothing dictating: it may start")
        assertFalse(DictationHandOffPolicy.mayStart(isDictating: true), "their dictation is running: leave it alone")
    }

    runSuite("The dictation island is only hidden for a hand-off take that really started") {
        assertTrue(DictationHandOffPolicy.overlayIsQuiet(startingHandOff: true), "a hand-off start keeps the island hidden")
        assertFalse(DictationHandOffPolicy.overlayIsQuiet(startingHandOff: false),
                    "a normal start shows the island even if an earlier hand-off left it hidden")
        assertTrue(DictationHandOffPolicy.overlayIsQuiet(afterHandOffStarted: true), "the hand-off is listening: still hidden")
        assertFalse(DictationHandOffPolicy.overlayIsQuiet(afterHandOffStarted: false),
                    "a refused hand-off start leaves nothing hidden for the next take")
    }

    runSuite("A hand-off take sends none of dictation's analytics; the person's own takes still do") {
        let mine = UUID()
        assertFalse(DictationHandOffPolicy.sendsAnalytics(isStartingHandOff: true, sessionID: UUID(), handOffSessionID: nil),
                    "while a hand-off is starting (start requested or refused): nothing")
        assertFalse(DictationHandOffPolicy.sendsAnalytics(isStartingHandOff: false, sessionID: mine, handOffSessionID: mine),
                    "the hand-off take itself (started, cancelled, failed): nothing")
        assertTrue(DictationHandOffPolicy.sendsAnalytics(isStartingHandOff: false, sessionID: UUID(), handOffSessionID: mine),
                   "the person's own take after it: counted as usual")
    }

    runSuite("After a hand-off take, the person's next dictation is counted and pasted as their own") {
        let old = UUID()
        assertNil(DictationHandOffPolicy.handOffSession(onStartRequest: old, startingHandOff: false, isDictating: false),
                  "their next start forgets the finished hand-off, before its own session exists")
        assertFalse(DictationHandOffPolicy.sendsAnalytics(isStartingHandOff: false, sessionID: old, handOffSessionID: old),
                    "without forgetting it, the stale id would hide their start from the counts")
        assertTrue(DictationHandOffPolicy.sendsAnalytics(isStartingHandOff: false, sessionID: old, handOffSessionID: nil),
                   "forgotten: their start is counted even while the old id is still current")
        assertEqual(DictationHandOffPolicy.handOffSession(onStartRequest: old, startingHandOff: false, isDictating: true), old,
                    "a press while the hand-off is still finishing keeps it, so its words still go to the card")
        assertEqual(DictationHandOffPolicy.handOffSession(onStartRequest: old, startingHandOff: true, isDictating: false), old,
                    "a new hand-off start keeps it until its own session replaces it")
    }

    runSuite("Words from a hand-off take that ended early are handed over once, and only to that take") {
        let mine = UUID()
        assertTrue(DictationHandOffPolicy.canClaim(unclaimedSessionID: mine, handOffSessionID: mine),
                   "stopped by the dictation key or the session cap: the card still gets the words")
        assertFalse(DictationHandOffPolicy.canClaim(unclaimedSessionID: nil, handOffSessionID: mine), "already handed over")
        assertFalse(DictationHandOffPolicy.canClaim(unclaimedSessionID: UUID(), handOffSessionID: mine),
                    "an older take's words never answer a newer one")
    }

    runSuite("Esc on the card throws away a hand-off take only while it's still recording") {
        let mine = UUID()
        assertTrue(DictationHandOffPolicy.mayCancel(currentSessionID: mine, handOffSessionID: mine, isDictating: true, isFinishing: false),
                   "still recording: it's thrown away")
        assertFalse(DictationHandOffPolicy.mayCancel(currentSessionID: mine, handOffSessionID: mine, isDictating: true, isFinishing: true),
                    "already finishing: leave it, so a dictation press queued meanwhile isn't dropped")
        assertFalse(DictationHandOffPolicy.mayCancel(currentSessionID: UUID(), handOffSessionID: mine, isDictating: true, isFinishing: false),
                    "never the person's own take")
    }

    runSuite("Write for Me can only stop its own take, never the person's dictation") {
        let mine = UUID()
        let theirs = UUID()
        assertTrue(DictationHandOffPolicy.mayStop(currentSessionID: mine, handOffSessionID: mine, isDictating: true),
                   "its own take, still running: it may stop it")
        assertFalse(DictationHandOffPolicy.mayStop(currentSessionID: theirs, handOffSessionID: mine, isDictating: true),
                    "a newer take is theirs: it's left running, and pasted as usual")
        assertFalse(DictationHandOffPolicy.mayStop(currentSessionID: mine, handOffSessionID: nil, isDictating: true),
                    "no hand-off was started: nothing to stop")
        assertFalse(DictationHandOffPolicy.mayStop(currentSessionID: mine, handOffSessionID: mine, isDictating: false),
                    "already finished: nothing to stop")
    }

    runSuite("A hand-off take's words go back however it was stopped; other takes paste as usual") {
        let mine = UUID()
        assertTrue(DictationHandOffPolicy.handsOff(sessionID: mine, handOffSessionID: mine), "its own take hands off")
        assertFalse(DictationHandOffPolicy.handsOff(sessionID: UUID(), handOffSessionID: mine), "any other take is pasted")
        assertFalse(DictationHandOffPolicy.handsOff(sessionID: mine, handOffSessionID: nil), "no hand-off, normal dictation")
        assertEqual(DictationHandOffPolicy.delivery, .savedWithoutPaste, "Dictations records it as saved, not pasted")
    }

    await runSuite("Finishing a hand-off take hands the words back, saves them, and puts the overlay away with no notice") {
        var ran: [String] = []
        var delivered: String?
        await DictationHandOffFinisher.finish(text: "make it warmer", steps: DictationHandOffFinisher.Steps(
            deliver: { delivered = $0; ran.append("deliver") },
            save: { ran.append("save"); return true },
            canPublish: { true },
            hideOverlay: { ran.append("hide") },
            endSession: { ran.append("end") }
        ))
        assertEqual(delivered, "make it warmer", "the card gets exactly what was said")
        assertEqual(ran, ["deliver", "save", "hide", "end"], "only these steps run: no notice, no telemetry")
    }

    await runSuite("A hand-off take that a newer take replaced still hands back its words but leaves the overlay alone") {
        var ran: [String] = []
        await DictationHandOffFinisher.finish(text: "shorter", steps: DictationHandOffFinisher.Steps(
            deliver: { _ in ran.append("deliver") },
            save: { ran.append("save"); return false },
            canPublish: { false },
            hideOverlay: { ran.append("hide") },
            endSession: { ran.append("end") }
        ))
        assertEqual(ran, ["deliver", "save"], "the newer take keeps its overlay and session")
    }


}
