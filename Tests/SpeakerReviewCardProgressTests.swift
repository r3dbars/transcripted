import Foundation

/// Promises of the Speakers page's review stack once a voice is named:
///   - picking someone already saved is a yes for them: their print lights
///     one more ring, and at the bar it fills and says "Auto" in their
///     color, the island's words;
///   - someone on probation reaching the bar is not promised auto-naming;
///   - a voice saved under a new name starts with one ring and "1 of 5";
///   - the done banner reads plainly.
func testSpeakerReviewCardProgress() {
    typealias Progress = SpeakerReviewCardProgress

    func voice(before: Int, after: Int? = nil, isNew: Bool = false, trusted: Bool = true) -> SpeakerReviewNamedVoice {
        SpeakerReviewNamedVoice(
            voiceID: UUID(), personID: UUID(), name: "Marcus Reed",
            confirmedBefore: before, confirmedAfter: after ?? before + 1, requiredMeetings: 5,
            isNewPerson: isNew, isTrusted: trusted
        )
    }

    runSuite("Joining a saved person at 4 of 5 fills their print and names them from now on") {
        let marcus = voice(before: 4)
        assertEqual(Progress.litRingsBefore(marcus), 4)
        assertEqual(Progress.litRingsAfter(marcus), 5, "the fifth yes fills the print")
        assertEqual(Progress.hint(marcus)?.text, "Auto")
        assertEqual(Progress.hint(marcus)?.usesPersonColor, true, "the payoff line is in the person's color")
    }

    runSuite("Joining a saved person part way lights one more ring and counts down") {
        let nina = voice(before: 2)
        assertEqual(Progress.litRingsBefore(nina), 2)
        assertEqual(Progress.litRingsAfter(nina), 3)
        assertEqual(Progress.hint(nina)?.text, "3 of 5")
        assertEqual(Progress.hint(nina)?.usesPersonColor, false)

        let almost = voice(before: 3)
        assertEqual(Progress.hint(almost)?.text, "4 of 5")
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
        assertEqual(Progress.hint(jordan)?.text, "1 of 5")
    }

    runSuite("The done banner reads plainly") {
        assertEqual(Progress.doneLine(callTitle: "Weekly sync", namedCount: 2), "Weekly sync is done · 2 voices named")
        assertEqual(Progress.doneLine(callTitle: "Weekly sync", namedCount: 1), "Weekly sync is done · 1 voice named")
        assertEqual(Progress.doneLine(callTitle: "Weekly sync", namedCount: 0), "Weekly sync is done")
        assertEqual(Progress.doneLine(callTitle: "  ", namedCount: 1), "This meeting is done · 1 voice named")

    }

    runSuite("Saved progress reflects distinct meetings rather than clicks") {
        let duplicate = voice(before: 4, after: 4)
        assertEqual(Progress.litRingsAfter(duplicate), 4)
        assertEqual(Progress.hint(duplicate)?.text, "4 of 5")
        let multiple = voice(before: 2, after: 5)
        assertEqual(Progress.litRingsAfter(multiple), 5)
        assertEqual(Progress.hint(multiple)?.text, "Auto")
        let newAcrossCalls = voice(before: 0, after: 3, isNew: true)
        assertEqual(Progress.litRingsAfter(newAcrossCalls), 3)
        assertEqual(Progress.hint(newAcrossCalls)?.text, "3 of 5")
        let untrustedNew = voice(before: 0, after: 5, isNew: true, trusted: false)
        assertEqual(Progress.litRingsAfter(untrustedNew), 4)
        assertNil(Progress.hint(untrustedNew))
    }
}
