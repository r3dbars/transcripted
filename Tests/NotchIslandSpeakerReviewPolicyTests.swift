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
}
