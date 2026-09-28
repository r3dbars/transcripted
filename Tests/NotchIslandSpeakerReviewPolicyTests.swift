import Foundation

func testNotchIslandSpeakerReviewPolicy() {
    runSuite("NotchIslandSpeakerReviewPolicy asks yes/no only when there is a suggestion") {
        assertEqual(
            NotchIslandSpeakerReviewPolicy.question(currentName: "Maya Chen", needsConfirmation: true),
            .confirm(name: "Maya Chen"),
            "a likely match asks Is this Maya Chen?"
        )
        assertEqual(
            NotchIslandSpeakerReviewPolicy.question(currentName: nil, needsConfirmation: false),
            .name,
            "a voice with no guess gets a name box"
        )
        assertEqual(
            NotchIslandSpeakerReviewPolicy.question(currentName: "  ", needsConfirmation: true),
            .name,
            "a blank suggestion is no suggestion"
        )
    }

    runSuite("NotchIslandSpeakerReviewPolicy shows three invitees, then an arrow") {
        let invitees = ["Dana Kim", "Luis Ortega", "Sam Ortiz", "Priya Shah", "Theo Park"]
        let first = NotchIslandSpeakerReviewPolicy.inviteeChips(invitees: invitees, alreadyUsed: [], showAll: false)
        assertEqual(first.shown, ["Dana Kim", "Luis Ortega", "Sam Ortiz"], "invite order, first three")
        assertEqual(first.hidden, 2, "the arrow says two more")

        let all = NotchIslandSpeakerReviewPolicy.inviteeChips(invitees: invitees, alreadyUsed: [], showAll: true)
        assertEqual(all.shown.count, 5, "the arrow reveals everyone")
        assertEqual(all.hidden, 0)

        let afterNaming = NotchIslandSpeakerReviewPolicy.inviteeChips(
            invitees: invitees,
            alreadyUsed: ["dana kim", "Theo Park"],
            showAll: false
        )
        assertEqual(afterNaming.shown, ["Luis Ortega", "Sam Ortiz", "Priya Shah"], "names already given drop out, case-insensitively")
        assertEqual(afterNaming.hidden, 0, "no arrow once three or fewer are left")

        let duplicates = NotchIslandSpeakerReviewPolicy.inviteeChips(invitees: ["Dana Kim", " dana kim ", ""], alreadyUsed: [], showAll: false)
        assertEqual(duplicates.shown, ["Dana Kim"], "blank and repeated invitees show once")
    }

    runSuite("NotchIslandSpeakerReviewPolicy autocompletes from saved people, invitees first") {
        let people: [(label: String, callCount: Int)] = [
            ("Priyanka Rao", 2),
            ("Priya Shah", 6),
            ("Maya Chen", 12),
        ]
        let none = NotchIslandSpeakerReviewPolicy.suggestions(query: "  ", people: people, invitees: ["Priya Shah"])
        assertTrue(none.isEmpty, "nothing typed, nothing suggested (the invitee chips cover it)")

        let pri = NotchIslandSpeakerReviewPolicy.suggestions(query: "Pri", people: people, invitees: ["Priya Shah"])
        assertEqual(pri.map(\.label), ["Priya Shah", "Priyanka Rao"], "the invitee leads, then saved people")
        assertEqual(pri.first?.detail, "on the invite · 6 calls")
        assertEqual(pri.last?.detail, "2 calls")

        let unsaved = NotchIslandSpeakerReviewPolicy.suggestions(query: "dan", people: people, invitees: ["Dana Kim"])
        assertEqual(unsaved.map(\.label), ["Dana Kim"], "an invitee nobody saved yet is still suggested")
        assertEqual(unsaved.first?.detail, "on the invite")

        let capped = NotchIslandSpeakerReviewPolicy.suggestions(
            query: "a",
            people: [("Ana", 1), ("Anna", 1), ("Aaron", 1), ("Alex", 1)],
            invitees: []
        )
        assertEqual(capped.count, NotchIslandSpeakerReviewPolicy.suggestionLimit, "at most three rows under the box")
    }

    runSuite("NotchIslandSpeakerReviewPolicy says what happened after Done") {
        assertEqual(NotchIslandSpeakerReviewPolicy.doneCopy(leftForLater: 0).title, "Everyone’s named")
        assertEqual(NotchIslandSpeakerReviewPolicy.doneCopy(leftForLater: 0).detail, "Next time they’re recognized on their own.")
        assertEqual(NotchIslandSpeakerReviewPolicy.doneCopy(leftForLater: 1).detail, "1 voice left to name in Speakers.")
        assertEqual(NotchIslandSpeakerReviewPolicy.doneCopy(leftForLater: 2).detail, "2 voices left to name in Speakers.")
        assertEqual(NotchIslandSpeakerReviewPolicy.headerTitle(meetingTitle: "Design sync"), "Who was on Design sync?")
        assertEqual(NotchIslandSpeakerReviewPolicy.headerTitle(meetingTitle: nil), "Who was on this call?")
    }

    runSuite("NotchIslandPresentation opens the speaker review by itself once the meeting is saved") {
        let review = NotchIslandSpeakerReviewContent(reviewID: UUID(), meetingTitle: "Design sync", stage: .naming)
        let layout = NotchIslandPresentation.layout(
            dictation: nil,
            meeting: NotchIslandMeetingContent(phase: .saved(title: "Design sync")),
            callPrompt: nil,
            recentInsert: nil,
            expanded: false,
            speakerReview: review
        )
        assertEqual(layout.drop, .speakerReview(review), "the review opens without a click")
        assertTrue(layout.dropIsSticky, "it stays open until answered")
        assertEqual(layout.left, [.symbol(.check, .accent), .text("Design sync", .title)], "the wing names the meeting")

        let recording = NotchIslandPresentation.layout(
            dictation: nil,
            meeting: NotchIslandMeetingContent(phase: .recording),
            callPrompt: nil,
            recentInsert: nil,
            expanded: false,
            speakerReview: review
        )
        assertTrue(recording.drop != .speakerReview(review), "it never asks while the next meeting records")

        let dictating = NotchIslandPresentation.layout(
            dictation: NotchIslandDictationContent(phase: .listening),
            meeting: nil,
            callPrompt: nil,
            recentInsert: nil,
            expanded: false,
            speakerReview: review
        )
        assertNil(dictating.drop, "it waits while a dictation runs")
    }

    runSuite("Return in the name box never swaps a typed name for a longer saved one") {
        typealias Policy = NotchIslandSpeakerReviewPolicy
        let christina = [Policy.Suggestion(label: "Christina Park", detail: "4 calls")]

        let rows = Policy.nameBoxRows(typed: "Chris", suggestions: christina)
        assertEqual(rows, [.saved("Christina Park"), .newPerson("Chris")], "the typed name is offered as a new person under the saved match")
        assertEqual(Policy.defaultHighlight(typed: "Chris", suggestions: christina), 1, "with no exact match the new-person row is highlighted")
        assertEqual(
            Policy.nameToSave(typed: "Chris", suggestions: christina, highlighted: nil),
            "Chris",
            "Return saves what was typed, not the top suggestion"
        )
        assertEqual(
            Policy.nameToSave(typed: "Chris", suggestions: christina, highlighted: 0),
            "Christina Park",
            "Return saves the saved person when you arrowed to them"
        )
        assertEqual(
            Policy.nameToSave(typed: "Chris", suggestions: christina, highlighted: 1),
            "Chris",
            "arrowing to the new-person row saves the typed name"
        )
    }

    runSuite("Return in the name box picks an exact saved match") {
        typealias Policy = NotchIslandSpeakerReviewPolicy
        let people = [
            Policy.Suggestion(label: "Christina Park", detail: "4 calls"),
            Policy.Suggestion(label: "Chris", detail: "2 calls"),
        ]
        assertEqual(Policy.nameBoxRows(typed: " chris ", suggestions: people), [.saved("Christina Park"), .saved("Chris")], "no new-person row when a saved person is exactly the typed name")
        assertEqual(Policy.defaultHighlight(typed: " chris ", suggestions: people), 1, "the exact match is highlighted, even when it isn't first")
        assertEqual(Policy.nameToSave(typed: " chris ", suggestions: people, highlighted: nil), "Chris", "Return saves the exact match under its saved spelling")
        assertEqual(Policy.nameToSave(typed: "Émile", suggestions: [Policy.Suggestion(label: "emile", detail: "1 call")], highlighted: nil), "emile", "case and accents don't make a new person")
        assertNil(Policy.nameToSave(typed: "   ", suggestions: people, highlighted: nil), "a blank box saves nothing")
        assertNil(Policy.defaultHighlight(typed: "", suggestions: []), "nothing to highlight in an empty box")
        assertEqual(Policy.nameToSave(typed: "Dana", suggestions: [], highlighted: nil), "Dana", "no suggestions: the typed name is a new person")
    }

    runSuite("Arrow keys reach every row under the name box, including the new person") {
        typealias Policy = NotchIslandSpeakerReviewPolicy
        let suggestions = [
            Policy.Suggestion(label: "Christina Park", detail: ""),
            Policy.Suggestion(label: "Christopher Lee", detail: ""),
        ]
        // Rows: Christina, Christopher, new "Chris". Default highlight is the new person (2).
        assertEqual(Policy.movedHighlight(from: nil, by: -1, typed: "Chris", suggestions: suggestions), 1, "up from the default goes to the row above it")
        assertEqual(Policy.movedHighlight(from: 0, by: 1, typed: "Chris", suggestions: suggestions), 1)
        assertEqual(Policy.movedHighlight(from: 1, by: 1, typed: "Chris", suggestions: suggestions), 2, "down reaches the new-person row")
        assertEqual(Policy.movedHighlight(from: 2, by: 1, typed: "Chris", suggestions: suggestions), 2, "down stops at the last row")
        assertEqual(Policy.movedHighlight(from: 0, by: -1, typed: "Chris", suggestions: suggestions), 0, "up stops at the first row")
        assertNil(Policy.movedHighlight(from: nil, by: 1, typed: "", suggestions: []), "nothing to move through in an empty box")
    }

    runSuite("Done and Later keep a name that was typed but not submitted") {
        typealias Policy = NotchIslandSpeakerReviewPolicy
        let christina = [Policy.Suggestion(label: "Christina Park", detail: "")]
        assertEqual(
            Policy.answerOnFinish(committed: nil, typed: "Chris", suggestions: christina, highlighted: nil),
            "Chris",
            "an open name box with text counts as that name, resolved like Return"
        )
        assertEqual(
            Policy.answerOnFinish(committed: nil, typed: "Chris", suggestions: christina, highlighted: 0),
            "Christina Park",
            "the arrowed-to suggestion counts, like Return"
        )
        assertEqual(
            Policy.answerOnFinish(committed: "Maya Chen", typed: "", suggestions: [], highlighted: nil),
            "Maya Chen",
            "a submitted name stands"
        )
        assertNil(Policy.answerOnFinish(committed: nil, typed: "  ", suggestions: [], highlighted: nil), "an empty box leaves the voice unnamed")
    }

    runSuite("The Later ring only runs while the review is on screen and not hovered") {
        typealias Policy = NotchIslandSpeakerReviewPolicy
        assertTrue(Policy.laterCountdownRuns(visible: true, hovered: false), "on screen and left alone: it counts down")
        assertFalse(Policy.laterCountdownRuns(visible: false, hovered: false), "hidden behind a dictation or a busy meeting: it waits")
        assertFalse(Policy.laterCountdownRuns(visible: true, hovered: true), "the pointer is on it: it waits")

        let review = NotchIslandSpeakerReviewContent(reviewID: UUID(), meetingTitle: nil, stage: .naming)
        let shown = NotchIslandPresentation.layout(
            dictation: nil, meeting: nil, callPrompt: nil, recentInsert: nil, expanded: false, speakerReview: review
        )
        assertTrue(shown.showsSpeakerReview, "a saved meeting's review is on screen")
        let hiddenByDictation = NotchIslandPresentation.layout(
            dictation: NotchIslandDictationContent(phase: .listening), meeting: nil, callPrompt: nil, recentInsert: nil, expanded: false, speakerReview: review
        )
        assertFalse(hiddenByDictation.showsSpeakerReview, "a dictation hides the review")
        let hiddenByRecording = NotchIslandPresentation.layout(
            dictation: nil, meeting: NotchIslandMeetingContent(phase: .recording), callPrompt: nil, recentInsert: nil, expanded: false, speakerReview: review
        )
        assertFalse(hiddenByRecording.showsSpeakerReview, "a new recording hides the review")
    }

    runSuite("A meeting where everyone was recognized still says who was on it") {
        typealias Policy = NotchIslandSpeakerReviewPolicy
        assertEqual(Policy.headerTitle(meetingTitle: nil, recognizedOnly: true), "On this call")
        assertEqual(Policy.headerTitle(meetingTitle: "Design sync", recognizedOnly: true), "On Design sync")
        assertEqual(Policy.headerTitle(meetingTitle: "Design sync", recognizedOnly: false), "Who was on Design sync?", "a review that asks still asks")
        assertEqual(Policy.correctionPrompt(name: "Taylor Wolf"), "Not Taylor?", "hover offers a correction by first name")
        assertEqual(Policy.correctionPrompt(name: "  Cher "), "Not Cher?")
        assertFalse(Policy.doneShowsSummary(recognizedOnly: true, updates: 0), "nothing corrected: Done just closes")
        assertTrue(Policy.doneShowsSummary(recognizedOnly: true, updates: 1), "a correction gets the saved summary")
        assertTrue(Policy.doneShowsSummary(recognizedOnly: false, updates: 0), "a review that asked always sums up")
    }
}
