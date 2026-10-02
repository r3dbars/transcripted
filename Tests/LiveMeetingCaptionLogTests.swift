import Foundation

func testLiveMeetingCaptionLog() {
    runSuite("LiveMeetingCaptionLog joins one speaker's utterances into a turn") {
        var log = LiveMeetingCaptionLog()
        log.commit("so the onboarding flow", track: .system)
        log.commit("drops people at step three", track: .system)
        log.commit("right, that's the permissions screen", track: .microphone)
        assertEqual(log.lines, [
            LiveMeetingCaptionLine(track: .system, text: "so the onboarding flow drops people at step three"),
            LiveMeetingCaptionLine(track: .microphone, text: "right, that's the permissions screen"),
        ])
    }

    runSuite("LiveMeetingCaptionLog only grows finished text at the end") {
        var log = LiveMeetingCaptionLog()
        log.commit("hello there", track: .microphone)
        let before = log.lines
        log.setTentative("how are", track: .system)
        log.commit("how are you", track: .system)
        log.commit("doing today", track: .system)
        assertEqual(Array(log.lines.prefix(before.count)), before, "earlier turns never change")
        assertNil(log.tentative[.system], "a finished utterance replaces the words still being heard")
    }

    runSuite("LiveMeetingCaptionLog Copy all labels turns and includes words still being heard") {
        var log = LiveMeetingCaptionLog()
        log.commit("signups were up", track: .microphone)
        log.commit("nice, and activation?", track: .system)
        log.setTentative("flat, which is", track: .microphone)
        assertEqual(
            log.plainText(),
            "You: signups were up\n\nThem: nice, and activation?\n\nYou: flat, which is"
        )

        var sameTurn = LiveMeetingCaptionLog()
        sameTurn.commit("is it the same", track: .system)
        sameTurn.setTentative("drop-off", track: .system)
        assertEqual(sameTurn.plainText(), "Them: is it the same drop-off", "the same speaker's pending words continue their turn")
    }

    runSuite("LiveMeetingCaptionLog ignores blank text and tidies spacing") {
        var log = LiveMeetingCaptionLog()
        log.commit("   ", track: .microphone)
        log.setTentative("\n", track: .system)
        assertTrue(log.isEmpty, "silence adds nothing")
        log.commit("  two   spaces\nand a newline ", track: .microphone)
        assertEqual(log.lines.first?.text, "two spaces and a newline")
    }

    runSuite("LiveMeetingCaptionLog drops the oldest turns past its limit") {
        var log = LiveMeetingCaptionLog(maximumCharacters: 20)
        log.commit("first turn here", track: .microphone)
        assertEqual(log.trimGeneration, 0)
        log.commit("second turn", track: .system)
        log.commit("third", track: .microphone)
        assertEqual(log.lines.map(\.text), ["second turn", "third"], "the newest turns stay")
        assertTrue(log.trimGeneration > 0, "a view knows to redraw once")
    }
}
