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

    runSuite("LiveMeetingCaptionLog starts a new line in a long monologue") {
        var log = LiveMeetingCaptionLog()
        let sentence = String(repeating: "word ", count: 60).trimmingCharacters(in: .whitespaces)
        for _ in 0..<10 { log.commit(sentence, track: .system) }
        assertTrue(log.lines.count > 1, "one speaker's hour-long talk doesn't become one ever-growing line")
        assertTrue(log.lines.allSatisfy { $0.track == .system }, "every line keeps its speaker")
        assertTrue(
            log.lines.allSatisfy { $0.text.utf8.count < LiveMeetingCaptionLog.longestLineBytes + sentence.utf8.count + 1 },
            "no line runs far past the limit"
        )
    }

    runSuite("LiveMeetingCaptionLog only signals a redraw when lines were dropped") {
        var log = LiveMeetingCaptionLog(maximumCharacters: 10)
        log.commit("a single line much longer than the limit", track: .microphone)
        log.commit("and more", track: .microphone)
        assertEqual(log.trimGeneration, 0, "a lone line can't be trimmed, so nothing changed for the view")
    }

    runSuite("LiveMeetingCaptionLog trims a quarter at a time so redraws stay rare") {
        var log = LiveMeetingCaptionLog(maximumCharacters: 100)
        var track = LiveMeetingTrack.microphone
        for index in 0..<40 {
            log.commit("turn \(index) has some words", track: track)
            track = track == .microphone ? .system : .microphone
        }
        assertTrue(log.trimGeneration < 20, "40 turns past the cap redraw a handful of times, not on every commit")
        assertEqual(log.lines.last?.text, "turn 39 has some words", "the newest turn is kept")
    }
}
