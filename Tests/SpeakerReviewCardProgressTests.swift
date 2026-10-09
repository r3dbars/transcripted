import Foundation

/// Promises of the Speakers page's review stack once a voice is named:
///   - picking someone already saved is a yes for them: their print lights
///     one more ring, and at the bar it fills and says "Named automatically
///     from now on" in their color, the island's words;
///   - someone on probation reaching the bar is not promised auto-naming;
///   - a voice saved under a new name starts with one ring and "Saved · 4 more
///     to auto-name";
///   - the done card and the closed summary card read plainly.
func testSpeakerReviewCardProgress() {
    typealias Progress = SpeakerReviewCardProgress

    func voice(before: Int, isNew: Bool = false, trusted: Bool = true) -> SpeakerReviewNamedVoice {
        SpeakerReviewNamedVoice(
            voiceID: UUID(), personID: UUID(), name: "Marcus Reed",
            confirmedBefore: before, requiredMeetings: 5,
            isNewPerson: isNew, isTrusted: trusted
        )
    }

    runSuite("Joining a saved person at 4 of 5 fills their print and names them from now on") {
        let marcus = voice(before: 4)
        assertEqual(Progress.litRingsBefore(marcus), 4)
        assertEqual(Progress.litRingsAfter(marcus), 5, "the fifth yes fills the print")
        assertEqual(Progress.hint(marcus)?.text, "Named automatically from now on")
        assertEqual(Progress.hint(marcus)?.usesPersonColor, true, "the payoff line is in the person's color")
    }

    runSuite("Joining a saved person part way lights one more ring and counts down") {
        let nina = voice(before: 2)
        assertEqual(Progress.litRingsBefore(nina), 2)
        assertEqual(Progress.litRingsAfter(nina), 3)
        assertEqual(Progress.hint(nina)?.text, "2 more to go")
        assertEqual(Progress.hint(nina)?.usesPersonColor, false)

        let almost = voice(before: 3)
        assertEqual(Progress.hint(almost)?.text, "1 more to go")
    }

    runSuite("Someone on probation reaching the bar isn't promised auto-naming") {
        let leo = voice(before: 5, trusted: false)
        assertEqual(Progress.litRingsAfter(leo), 4, "a paused person never shows a full print")
        assertNil(Progress.hint(leo), "no promise the health check may still withhold")
    }

    runSuite("A voice saved under a new name starts with one ring") {
        let jordan = voice(before: 0, isNew: true)
        assertEqual(Progress.confirmedAfter(jordan), 1)
        assertEqual(Progress.litRingsBefore(jordan), 0)
        assertEqual(Progress.litRingsAfter(jordan), 1)
        assertEqual(Progress.hint(jordan)?.text, "Saved · 4 more to auto-name")
    }

    runSuite("The done card and summary card read plainly") {
        assertEqual(Progress.doneLine(callTitle: "Weekly sync", namedCount: 2), "Weekly sync is done · 2 voices named")
        assertEqual(Progress.doneLine(callTitle: "Weekly sync", namedCount: 1), "Weekly sync is done · 1 voice named")
        assertEqual(Progress.doneLine(callTitle: "Weekly sync", namedCount: 0), "Weekly sync is done")
        assertEqual(Progress.doneLine(callTitle: "  ", namedCount: 1), "This call is done · 1 voice named")

        assertEqual(Progress.nextTitle(callsAfterThis: 1), "Next call")
        assertEqual(Progress.nextTitle(callsAfterThis: 0), "Done")

        assertEqual(Progress.summaryTitle(voiceCount: 1), "1 voice to name")
        assertEqual(Progress.summaryTitle(voiceCount: 3), "3 voices to name")

        assertEqual(Progress.summarySource(callTitles: ["Weekly sync"]), "From Weekly sync")
        assertEqual(Progress.summarySource(callTitles: ["Weekly sync", "Design review"]), "From Weekly sync and Design review")
        assertEqual(Progress.summarySource(callTitles: ["Weekly sync", "Design review", "Planning"]), "From Weekly sync and 2 other calls")
        assertNil(Progress.summarySource(callTitles: []))
        assertNil(Progress.summarySource(callTitles: [" "]), "blank titles say nothing rather than \"From \"")
    }
}
