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
            people: [("Ana", 1), ("Anna", 1), ("Aaron", 1), ("Alex", 1), ("Abe", 1), ("Ada", 1)],
            invitees: []
        )
        assertEqual(capped.count, 5, "at most five rows under the box")
    }

    runSuite("NotchIslandSpeakerReviewPolicy swaps the invitee chips for the list once you type") {
        typealias Policy = NotchIslandSpeakerReviewPolicy
        assertTrue(Policy.showsInviteeChips(typed: ""), "an empty box shows the invitee chips")
        assertTrue(Policy.showsInviteeChips(typed: "  "), "spaces alone still count as empty")
        assertFalse(Policy.showsInviteeChips(typed: "J"), "one letter hides the chips so the list can take over")
        assertEqual(Policy.NameBoxRow.newPerson("Jo").displayTitle, "Add \u{201C}Jo\u{201D}", "the typed name reads as adding someone new")
        assertEqual(Policy.NameBoxRow.newPerson("Jo").label, "Jo", "but it saves just the typed name")
        assertEqual(Policy.NameBoxRow.saved("Jordan Lee").displayTitle, "Jordan Lee")
    }

    runSuite("NotchIslandSpeakerReviewPolicy offers Me on a local mic voice while typing") {
        typealias Policy = NotchIslandSpeakerReviewPolicy
        let people: [(label: String, callCount: Int)] = [("Megan Fox", 2), ("Jordan Lee", 4)]
        let mic = Policy.suggestions(query: "me", people: people, invitees: [], includeOwner: true)
        assertEqual(mic.map(\.label), ["You", "Megan Fox"], "Me leads on your own mic, then the saved match")
        assertEqual(Policy.NameBoxRow.saved(mic[0].label).displayTitle, "Me", "your own voice reads as Me")
        assertEqual(Policy.nameBoxRows(typed: "Me", suggestions: mic), [.saved("You"), .saved("Megan Fox")], "typing Me is an exact match, not a new person")
        let remote = Policy.suggestions(query: "me", people: people, invitees: [], includeOwner: false)
        assertEqual(remote.map(\.label), ["Megan Fox"], "a remote voice is never offered as Me")
        assertEqual(Policy.suggestions(query: "jo", people: people, invitees: [], includeOwner: true).map(\.label), ["Jordan Lee"], "Me only shows when the typing could be me")
    }

    runSuite("Each review row says the approved words: a question, a name, or the name field") {
        typealias Policy = NotchIslandSpeakerReviewPolicy
        assertEqual(Policy.rowTitle(.asking, name: " Marcus Reed "), "Marcus Reed?", "a likely match reads as a question")
        assertTrue(Policy.titleIsUnanswered(.asking), "and stays dimmer until answered")
        assertEqual(Policy.rowTitle(.confirmed, name: "Marcus Reed"), "Marcus Reed", "after ✓ just the name")
        assertFalse(Policy.titleIsUnanswered(.confirmed))
        assertEqual(Policy.rowTitle(.recognized, name: "Priya Shah"), "Priya Shah", "a voice named silently shows only the name")
        assertNil(Policy.rowTitle(.naming(.unknownVoice), name: nil), "an unknown voice's title is the name field")
        assertNil(Policy.rowTitle(.naming(.rejectedSuggestion), name: "Marcus Reed"), "after ✕ the title becomes the name field")
        assertEqual(Policy.rowTitle(.named(.newPerson), name: "Jo Park"), "Jo Park")
        assertEqual(Policy.rowTitle(.locked(.keptAsYou), name: nil), "Saved as You")
        assertEqual(Policy.rowTitle(.locked(.discarded), name: "Speaker 2"), "Not saved to People")
    }

    runSuite("Each review row offers the approved buttons") {
        typealias Policy = NotchIslandSpeakerReviewPolicy
        assertEqual(Policy.rowControls(.asking, hovered: false), [.no, .yes], "round ✕ then round ✓")
        assertEqual(Policy.rowControls(.confirmed, hovered: false), [.undo], "an answer can be undone")
        assertEqual(Policy.rowControls(.named(.newPerson), hovered: true), [.undo])
        assertEqual(Policy.rowControls(.recognized, hovered: false), [], "a voice named silently: no checkmark, no buttons")
        assertEqual(Policy.rowControls(.recognized, hovered: true), [.correct], "hovering it offers Not Priya?")
        assertEqual(Policy.rowControls(.naming(.correctingRecognized), hovered: false), [.keep], "the correction can be taken back")
        assertEqual(Policy.rowControls(.naming(.rejectedSuggestion), hovered: false), [.discard, .undo], "after ✕: Not a person, or ask again")
        assertEqual(Policy.rowControls(.naming(.unknownVoice), hovered: false), [.discard], "an unknown voice can still be Not a person")
        assertEqual(Policy.rowControls(.locked(.discarded), hovered: false), [.undoDiscard])
        assertEqual(Policy.rowControls(.locked(.keptAsYou), hovered: true), [], "All me is undone from the section header")
        assertEqual(Policy.correctionPrompt(name: "Priya Shah"), "Not Priya?")
    }

    runSuite("A print lights one ring per confirmed meeting, and ✓ shows the ring it earns") {
        typealias Policy = NotchIslandSpeakerReviewPolicy
        let marcus = Policy.Progress(confirmed: 4, required: 5)
        assertEqual(Policy.litRings(.asking, progress: marcus), 4, "asking shows what is already earned")
        assertEqual(Policy.litRings(.confirmed, progress: marcus), 5, "✓ completes it")
        assertEqual(Policy.litRings(.naming(.rejectedSuggestion), progress: marcus), 0, "after ✕ the row no longer claims Marcus")
        let dana = Policy.Progress(confirmed: 1, required: 5)
        assertEqual(Policy.litRings(.asking, progress: dana), 1)
        assertEqual(Policy.litRings(.confirmed, progress: dana), 2)
        assertEqual(Policy.litRings(.recognized, progress: Policy.Progress(confirmed: 9, required: 5)), 5, "named silently: a full print")
        assertEqual(Policy.litRings(.recognized, progress: nil), 5, "named silently with no count reported is still a full print")
        assertEqual(Policy.litRings(.asking, progress: nil), 0, "no count reported: an empty print")
        assertEqual(Policy.litRings(.named(.newPerson), progress: nil), 1, "a new name lights the first ring")
        assertEqual(Policy.litRings(.named(.savedPerson), progress: nil), 0, "a saved person's count isn't known here, so nothing is claimed")
        assertEqual(Policy.litRings(.locked(.keptAsYou), progress: marcus), 0)
        assertEqual(Policy.litRings(.locked(.discarded), progress: marcus), 0)
    }

    runSuite("A lineup meeting's lower bar scales the print, and probation never shows a full one") {
        typealias Policy = NotchIslandSpeakerReviewPolicy
        let lineup = Policy.Progress(confirmed: 1, required: 2)
        assertEqual(Policy.litRings(.asking, progress: lineup), 2, "1 of 2 lights half the print, rounded down")
        assertEqual(Policy.litRings(.confirmed, progress: lineup), 5, "reaching the lineup bar completes it")
        let probation = Policy.Progress(confirmed: 6, required: 5, isTrusted: false)
        assertEqual(Policy.litRings(.asking, progress: probation), 4, "past the bar but on probation: one ring short")
        assertEqual(Policy.litRings(.confirmed, progress: probation), 4, "a yes doesn't promise auto-naming the health check may withhold")
    }

    runSuite("The line under the name uses the shared copy, in the person's color for the payoff") {
        typealias Policy = NotchIslandSpeakerReviewPolicy
        let marcus = Policy.Progress(confirmed: 4, required: 5)
        assertEqual(Policy.rowHint(.asking, progress: marcus), SpeakerNamingTierPresentation.ReviewHint(text: "One more yes to auto-name", usesPersonColor: true))
        assertEqual(Policy.rowHint(.confirmed, progress: marcus), SpeakerNamingTierPresentation.ReviewHint(text: "Named automatically from now on", usesPersonColor: true))
        let dana = Policy.Progress(confirmed: 1, required: 5)
        assertNil(Policy.rowHint(.asking, progress: dana), "nothing under a name with more than one yes to go")
        assertEqual(Policy.rowHint(.confirmed, progress: dana), SpeakerNamingTierPresentation.ReviewHint(text: "3 more to go", usesPersonColor: false))
        assertEqual(Policy.rowHint(.named(.newPerson), progress: nil), SpeakerNamingTierPresentation.ReviewHint(text: "Saved · 4 more to auto-name", usesPersonColor: false))
        assertNil(Policy.rowHint(.recognized, progress: Policy.Progress(confirmed: 7, required: 5)), "no words under a name given silently")
        assertNil(Policy.rowHint(.named(.savedPerson), progress: nil))
        assertNil(Policy.rowHint(.naming(.unknownVoice), progress: nil))
        assertEqual(
            Policy.rowHint(.naming(.unknownVoice), progress: nil, prefilledUntouched: true)?.text,
            "Filled in from your calendar",
            "a calendar 1:1 name says where it came from"
        )
    }

    runSuite("The match animation plays on ✓ and on naming a new voice, and colors go to people the rows claim") {
        typealias Policy = NotchIslandSpeakerReviewPolicy
        assertTrue(Policy.celebrates(.confirmed))
        assertTrue(Policy.celebrates(.named(.newPerson)))
        assertTrue(Policy.celebrates(.named(.savedPerson)), "picking a saved person is a yes for them, so their print animates")
        assertFalse(Policy.celebrates(.asking))
        assertFalse(Policy.celebrates(.recognized))
        assertTrue(Policy.claimsPerson(.asking))
        assertTrue(Policy.claimsPerson(.recognized))
        assertTrue(Policy.claimsPerson(.named(.savedPerson)))
        assertFalse(Policy.claimsPerson(.naming(.unknownVoice)), "an unnamed voice doesn't use up a color")
        assertFalse(Policy.claimsPerson(.named(.owner)))
        assertFalse(Policy.claimsPerson(.locked(.discarded)))

        let voice = UUID(), saved = UUID(), picked = UUID()
        assertEqual(Policy.printOwner(.asking, voiceID: voice, suggestedID: saved, pickedID: nil), saved, "Is this Marcus? draws Marcus's own print")
        assertEqual(Policy.printOwner(.recognized, voiceID: voice, suggestedID: nil, pickedID: nil), voice)
        assertEqual(Policy.printOwner(.named(.savedPerson), voiceID: voice, suggestedID: saved, pickedID: picked), picked, "a picked person's print")
        assertEqual(Policy.printOwner(.named(.newPerson), voiceID: voice, suggestedID: saved, pickedID: nil), voice, "a new person keeps this voice's print")
        assertEqual(Policy.printOwner(.naming(.rejectedSuggestion), voiceID: voice, suggestedID: saved, pickedID: nil), voice)
    }

    runSuite("The footer counts each saved person once across split voices and plain names") {
        typealias Policy = NotchIslandSpeakerReviewPolicy
        let first = UUID(), second = UUID()
        let recognized = Policy.footerPersonKey(personID: first, fallback: "recognized-row")
        let confirmed = Policy.footerPersonKey(personID: first, fallback: "confirmed-row")
        let plain = Policy.footerPersonKey(personID: first, name: "Maya Chen", fallback: "plain")
        let other = Policy.footerPersonKey(personID: second, name: "Maya Chen", fallback: "other-row")
        let entries = [(key: recognized, origin: "recognized", lands: false),
                       (key: plain, origin: "plain", lands: false),
                       (key: confirmed, origin: "confirmed", lands: true),
                       (key: other, origin: "other", lands: true)]
        let unique = Policy.uniqueFooterPeople(entries, key: { $0.key })
        assertEqual(unique.count, 2, "three qualifying voices for one person produce only one dot")
        assertEqual(unique.map(\.origin), ["recognized", "other"], "first qualifying origin and row order survive")
        assertEqual(unique.map(\.lands), [false, true], "a recognized person's dot does not acquire a duplicate's delayed landing")
        assertEqual(Policy.footerPersonKey(personID: nil, name: " Maya Chen ", fallback: "plain-one"),
                    Policy.footerPersonKey(personID: nil, name: "maya chen", fallback: "plain-two"), "unresolved plain names deduplicate by normalized name")
        assertFalse(recognized == other, "different saved people must not merge because their display names match")
    }

    runSuite("The footer keeps the first qualifying landing and recomputes it on undo") {
        typealias Policy = NotchIslandSpeakerReviewPolicy
        let person = UUID()
        let key = Policy.footerPersonKey(personID: person, fallback: "unused")
        let first = (key: key, origin: "first-row", lands: true)
        let duplicate = (key: key, origin: "second-row", lands: true)
        let both = Policy.uniqueFooterPeople([first, duplicate], key: { $0.key })
        assertEqual(both.map(\.origin), ["first-row"], "one landing originates from the first qualifying row")
        assertEqual(both.map(\.lands), [true])
        let afterUndo = Policy.uniqueFooterPeople([duplicate], key: { $0.key })
        assertEqual(afterUndo.map(\.origin), ["second-row"], "undoing one voice preserves the other qualifying claim")
        assertEqual(afterUndo.map(\.key), both.map(\.key), "the same person keeps the stable footer identity")
        let afterAllUndone = Policy.uniqueFooterPeople([first, duplicate].filter { _ in false }, key: { $0.key })
        assertTrue(afterAllUndone.isEmpty, "undoing every qualifying row removes the person's dot and pending landing")
    }

    runSuite("The footer counts people named automatically on this call") {
        typealias Policy = NotchIslandSpeakerReviewPolicy
        assertTrue(Policy.namedAutomatically(.recognized, progress: nil), "a voice named silently counts")
        assertTrue(Policy.namedAutomatically(.confirmed, progress: Policy.Progress(confirmed: 4, required: 5)), "a ✓ that completes the print joins")
        assertFalse(Policy.namedAutomatically(.confirmed, progress: Policy.Progress(confirmed: 1, required: 5)))
        assertFalse(Policy.namedAutomatically(.confirmed, progress: Policy.Progress(confirmed: 6, required: 5, isTrusted: false)), "probation doesn't count")
        assertFalse(Policy.namedAutomatically(.asking, progress: Policy.Progress(confirmed: 4, required: 5)))
        assertFalse(Policy.namedAutomatically(.naming(.correctingRecognized), progress: nil), "Not Priya? takes Priya's dot away")
        assertEqual(SpeakerNamingTierPresentation.autoNamedFooter(count: 2), "2 people named automatically")
        assertNil(SpeakerNamingTierPresentation.autoNamedFooter(count: 0))
    }

    runSuite("The print's tip and VoiceOver say how far the person is") {
        typealias Policy = NotchIslandSpeakerReviewPolicy
        assertEqual(
            Policy.printExplanation(.asking, name: "Marcus Reed", progress: Policy.Progress(confirmed: 4, required: 5)),
            "Confirmed in 4 meetings. One more and Transcripted names Marcus on its own."
        )
        assertEqual(
            Policy.printExplanation(.confirmed, name: "Marcus Reed", progress: Policy.Progress(confirmed: 4, required: 5)),
            "Confirmed in 5 meetings. Transcripted names Marcus on its own when the voice is a clear match.",
            "after ✓ the tip counts the yes"
        )
        assertEqual(Policy.printExplanation(.naming(.unknownVoice), name: nil, progress: nil), "Press play to listen.")
        assertEqual(Policy.rowAccessibilityLabel(.asking, name: "Marcus Reed", hint: "One more yes to auto-name"), "Is this Marcus Reed? One more yes to auto-name", "no period after a question mark")
        assertEqual(Policy.rowAccessibilityLabel(.confirmed, name: "Marcus Reed", hint: "Named automatically from now on"), "Marcus Reed, confirmed. Named automatically from now on")
        assertEqual(Policy.rowAccessibilityLabel(.named(.newPerson), name: "Jo Park", hint: nil), "Jo Park, named")
        assertEqual(Policy.rowAccessibilityLabel(.named(.savedPerson), name: "Dana Lee", hint: nil, corrected: true), "Dana Lee, corrected", "a fix to a name Transcripted gave says so")
        assertEqual(Policy.rowAccessibilityLabel(.recognized, name: "Priya Shah", hint: nil), "Priya Shah, named automatically")
        assertEqual(Policy.rowAccessibilityLabel(.naming(.unknownVoice), name: nil, hint: nil), "Unnamed voice")
    }

    runSuite("Invitee chips fade in under the name field only while it has the keyboard") {
        typealias Policy = NotchIslandSpeakerReviewPolicy
        assertTrue(Policy.showsInviteeChips(typed: "", focused: true), "focused and empty: one-tap names")
        assertFalse(Policy.showsInviteeChips(typed: "", focused: false), "not focused: just the title")
        assertFalse(Policy.showsInviteeChips(typed: "Jo", focused: true), "typing swaps them for the list")
    }

    runSuite("NotchIslandSpeakerReviewPolicy says what happened after Done") {
        assertEqual(NotchIslandSpeakerReviewPolicy.doneCopy(leftForLater: 0).title, "Everyone’s named")
        assertEqual(NotchIslandSpeakerReviewPolicy.doneCopy(leftForLater: 0).detail, "After a few confirmed meetings, Transcripted names them on its own.")
        assertEqual(NotchIslandSpeakerReviewPolicy.doneCopy(leftForLater: 1).detail, "1 left to name in Speakers.")
        assertEqual(NotchIslandSpeakerReviewPolicy.doneCopy(leftForLater: 2).detail, "2 left to name in Speakers.")
        assertEqual(NotchIslandSpeakerReviewPolicy.headerTitle, "Who spoke?", "the header asks one short question")
        assertEqual(NotchIslandSpeakerReviewPolicy.headerDetail(meetingTitle: " Design sync "), "Design sync", "the meeting sits small on the right")
        assertNil(NotchIslandSpeakerReviewPolicy.headerDetail(meetingTitle: "  "), "no meeting name, nothing on the right")
        assertEqual(NotchIslandSpeakerReviewPolicy.accessibilityTitle(meetingTitle: "Design sync"), "Who spoke? Design sync")
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

    runSuite("A who-was-on-the-call list offers corrections and closes quietly when nothing changed") {
        typealias Policy = NotchIslandSpeakerReviewPolicy
        assertEqual(Policy.correctionPrompt(name: "Taylor Wolf"), "Not Taylor?", "hover offers a correction by first name")
        assertEqual(Policy.correctionPrompt(name: "  Cher "), "Not Cher?")
        assertFalse(Policy.doneShowsSummary(recognizedOnly: true, updates: 0), "nothing corrected: Done just closes")
        assertTrue(Policy.doneShowsSummary(recognizedOnly: true, updates: 1), "a correction gets the saved summary")
        assertTrue(Policy.doneShowsSummary(recognizedOnly: false, updates: 0), "a review that asked always sums up")
    }

    runSuite("A who-was-on-the-call list closes itself even while hidden; a review that asks waits") {
        typealias Policy = NotchIslandSpeakerReviewPolicy
        assertEqual(Policy.hardCapSeconds(recognizedOnly: true), 120, "nothing to answer: about two minutes, on screen or not")
        assertTrue(Policy.hardCapSeconds(recognizedOnly: false) == nil, "a review with voices to name waits for answers")
        assertTrue(
            (Policy.hardCapSeconds(recognizedOnly: true) ?? 0) > Policy.laterSeconds,
            "the cap never cuts the on-screen Later ring short"
        )
        assertTrue(Policy.hardCapClosesNow(hovered: false, answering: false), "nobody on it: it closes at the cap")
        assertFalse(Policy.hardCapClosesNow(hovered: true, answering: false), "the pointer on it holds the close until it leaves")
    }

    runSuite("The who-was-on-the-call cap never closes a review while someone is answering") {
        typealias Policy = NotchIslandSpeakerReviewPolicy
        assertFalse(
            Policy.hardCapClosesNow(hovered: false, answering: true),
            "a \"Not Taylor?\" box was opened: the pointer leaving must not close it mid-answer"
        )
        assertFalse(Policy.hardCapClosesNow(hovered: true, answering: true), "still answering with the pointer on it")
    }

    runSuite("A correction on a recognized voice reports that voice's match") {
        typealias Policy = NotchIslandSpeakerReviewPolicy
        struct Voice: Equatable { let key: String; let similarity: Double }
        let asked = [Voice(key: "system_0", similarity: 0.61)]
        let recognized = [Voice(key: "system_1", similarity: 0.93), Voice(key: "system_0", similarity: 0.99)]
        let byKey = Policy.entriesByKey(asked: asked, recognized: recognized, key: \.key)
        assertEqual(byKey["system_1"], Voice(key: "system_1", similarity: 0.93), "Not Taylor? finds the recognized voice")
        assertEqual(byKey["system_0"], Voice(key: "system_0", similarity: 0.61), "an asked voice wins a shared key")
        assertTrue(byKey["mic_1"] == nil)
    }

    runSuite("A verdict on a silently named voice is reported as auto_recognized, so wrong silent names can be counted") {
        typealias Policy = NotchIslandSpeakerReviewPolicy
        struct Voice { let key: String }
        let asked = [Voice(key: "system_0"), Voice(key: "mic_0")]
        let recognized = [Voice(key: "system_1"), Voice(key: "system_2"), Voice(key: "system_0")]
        let auto = Policy.autoRecognizedKeys(asked: asked, recognized: recognized, key: \.key)
        assertEqual(auto, ["system_1", "system_2"], "an asked voice wins a shared key, as in entriesByKey")
        assertEqual(Policy.autoRecognizedProperty(updateKey: "system_1", autoRecognizedKeys: auto), "true", "Not Priya? on a recognized voice")
        assertEqual(Policy.autoRecognizedProperty(updateKey: "system_0", autoRecognizedKeys: auto), "false", "an asked Is this …? voice")
        assertEqual(Policy.autoRecognizedProperty(updateKey: "mic_0", autoRecognizedKeys: auto), "false")
        assertEqual(Policy.autoRecognizedProperty(updateKey: "system_9", autoRecognizedKeys: auto), "false", "an unknown voice is not auto-recognized")
        assertEqual(Policy.autoRecognizedKeys(asked: asked, recognized: [Voice](), key: \.key), [], "a review with nobody recognized")
    }

    runSuite("A calendar 1:1 fills the one unnamed remote voice with the other invitee") {
        typealias Policy = NotchIslandSpeakerReviewPolicy
        assertEqual(
            Policy.oneOnOnePrefill(invitees: ["Dana Kim"], remoteVoicesInMeeting: 1, askedRemoteVoicesHaveSuggestion: [false]),
            "Dana Kim",
            "one invitee, one remote voice, no guess: fill in the invitee"
        )
        assertNil(
            Policy.oneOnOnePrefill(invitees: ["Dana Kim", "Luis Ortega"], remoteVoicesInMeeting: 1, askedRemoteVoicesHaveSuggestion: [false]),
            "a group invite fills nothing"
        )
        assertNil(
            Policy.oneOnOnePrefill(invitees: ["Dana Kim"], remoteVoicesInMeeting: 2, askedRemoteVoicesHaveSuggestion: [false]),
            "a second remote voice (even one recognized and not asked) fills nothing"
        )
        assertNil(
            Policy.oneOnOnePrefill(invitees: ["Dana Kim"], remoteVoicesInMeeting: nil, askedRemoteVoicesHaveSuggestion: [false]),
            "an unknown voice count fills nothing"
        )
        assertNil(
            Policy.oneOnOnePrefill(invitees: ["Dana Kim"], remoteVoicesInMeeting: 1, askedRemoteVoicesHaveSuggestion: [true]),
            "a voice that already has a guess keeps its Is this …? question"
        )
        assertNil(
            Policy.oneOnOnePrefill(invitees: ["Dana Kim"], remoteVoicesInMeeting: 1, askedRemoteVoicesHaveSuggestion: []),
            "nothing remote is asked about: nothing to fill"
        )
    }

    runSuite("A calendar name nobody touched saves on Done, not on Later") {
        typealias Policy = NotchIslandSpeakerReviewPolicy
        assertEqual(
            Policy.answerOnFinish(committed: nil, typed: "Dana Kim", suggestions: [], highlighted: nil, typedIsUntouchedPrefill: true, finish: .done),
            "Dana Kim",
            "Done confirms the filled-in name like a typed one"
        )
        assertNil(
            Policy.answerOnFinish(committed: nil, typed: "Dana Kim", suggestions: [], highlighted: nil, typedIsUntouchedPrefill: true, finish: .later),
            "Later (or its ring) never saves a name the person didn't look at"
        )
        assertEqual(
            Policy.answerOnFinish(committed: nil, typed: "Dana", suggestions: [], highlighted: nil, typedIsUntouchedPrefill: false, finish: .later),
            "Dana",
            "a name the person typed still counts on Later"
        )
        assertEqual(
            Policy.answerOnFinish(committed: "Dana Kim", typed: "", suggestions: [], highlighted: nil, typedIsUntouchedPrefill: true, finish: .later),
            "Dana Kim",
            "a submitted name stands on Later"
        )
    }

    runSuite("Keep Local Mic as You covers every local mic voice and wins over a discard") {
        typealias Policy = NotchIslandSpeakerReviewPolicy
        assertEqual(Policy.lock(isMic: true, keepMicAsYou: true, discarded: false), .keptAsYou)
        assertEqual(Policy.lock(isMic: true, keepMicAsYou: true, discarded: true), .keptAsYou, "Keep as You wins, as in the review window")
        assertEqual(Policy.lock(isMic: false, keepMicAsYou: true, discarded: false), nil, "remote voices are never kept as You")
        assertEqual(Policy.lock(isMic: false, keepMicAsYou: true, discarded: true), .discarded)
        assertEqual(Policy.lock(isMic: true, keepMicAsYou: false, discarded: true), .discarded)
        assertEqual(Policy.lock(isMic: true, keepMicAsYou: false, discarded: false), nil, "a voice left alone is asked as usual")
        assertEqual(Policy.keepAsYouTitle(keepMicAsYou: false), "All me")
        assertEqual(Policy.keepAsYouTitle(keepMicAsYou: true), "Undo", "pressing it again lifts it")
        assertEqual(Policy.lockNote(.keptAsYou), "Saved as You")
    }

    runSuite("Discard Voice is offered on an asked voice with its name box open") {
        typealias Policy = NotchIslandSpeakerReviewPolicy
        assertTrue(Policy.offersDiscard(isRecognized: false, nameBoxOpen: true, keptAsYou: false), "an unknown voice can be thrown away")
        assertFalse(Policy.offersDiscard(isRecognized: false, nameBoxOpen: false, keptAsYou: false), "Is this Maya? asks Yes/No first; No opens the box")
        assertFalse(Policy.offersDiscard(isRecognized: true, nameBoxOpen: true, keptAsYou: false), "a recognized voice is corrected, not discarded")
        assertFalse(Policy.offersDiscard(isRecognized: false, nameBoxOpen: true, keptAsYou: true), "not while kept as You")
        assertEqual(Policy.discardTitle(discarded: false), "Not a person")
        assertEqual(Policy.discardTitle(discarded: true), "Undo")
        assertEqual(Policy.lockNote(.discarded), "Not saved to People")
    }

    runSuite("Undo goes back to the question, or to the field a name came from") {
        typealias Policy = NotchIslandSpeakerReviewPolicy
        assertEqual(Policy.undoTarget(.confirmed, origin: .rejectedSuggestion), .asking, "after ✓: Marcus Reed? again")
        assertEqual(Policy.undoTarget(.naming(.rejectedSuggestion), origin: .rejectedSuggestion), .asking, "after ✕: Marcus Reed? again, not an empty field")
        assertEqual(Policy.undoTarget(.named(.newPerson), origin: .rejectedSuggestion), .naming(.rejectedSuggestion), "a name typed after ✕ goes back to that field")
        assertEqual(Policy.undoTarget(.named(.savedPerson), origin: .unknownVoice), .naming(.unknownVoice), "a name for an unknown voice goes back to Who's this?")
        assertEqual(Policy.undoTarget(.named(.newPerson), origin: .correctingRecognized), .naming(.correctingRecognized), "a correction goes back to the Not Priya? field")
    }

    runSuite("Moving on takes the keyboard only for a row whose title is the name field") {
        typealias Policy = NotchIslandSpeakerReviewPolicy
        assertFalse(Policy.takesKeyboardOnAdvance(.asking), "Marcus Reed? has nothing to type into")
        assertTrue(Policy.takesKeyboardOnAdvance(.naming(.unknownVoice)), "Who's this? does")
        assertTrue(Policy.takesKeyboardOnAdvance(.naming(.rejectedSuggestion)))
        assertFalse(Policy.takesKeyboardOnAdvance(.recognized))
        assertFalse(Policy.takesKeyboardOnAdvance(.locked(.keptAsYou)))
        for state in [Policy.RowState.asking, .naming(.unknownVoice), .naming(.rejectedSuggestion), .confirmed, .recognized] {
            assertEqual(Policy.takesKeyboardOnAdvance(state), Policy.rowTitle(state, name: "Dana Lee") == nil, "keyboard only where the title is the field")
        }
    }

    runSuite("A person's color stays theirs for the whole review") {
        typealias Policy = NotchIslandSpeakerReviewPolicy
        // Find two people who prefer the same color, so the second is bumped.
        let ids = (0..<64).compactMap { UUID(uuidString: String(format: "00000000-0000-4000-8000-%012x", $0)) }
        var byPreferred: [Int: UUID] = [:]
        var pair: (UUID, UUID)?
        for id in ids {
            let preferred = VoicePrintStyle(id: id).preferredColorIndex
            if let first = byPreferred[preferred] { pair = (first, id); break }
            byPreferred[preferred] = id
        }
        guard let (first, second) = pair else { return assertTrue(false, "9 or more ids always share one of 8 colors") }
        let start = Policy.colorOrder(existing: [], claims: [first, second])
        let startColors = VoicePrintStyle.colorIndices(for: start)
        assertEqual(start, [first, second], "first time: row order")
        assertEqual(startColors, VoicePrintStyle.colorIndices(for: [first, second]), "the same colors as plain row order")

        // ✕ on the first row: it stops claiming anyone. The second keeps its color.
        let afterNo = Policy.colorOrder(existing: start, claims: [second])
        assertEqual(VoicePrintStyle.colorIndices(for: afterNo)[second], startColors[second], "nobody is recolored when another row lets go")

        // A voice named above them joins at the end and doesn't take their colors.
        let newcomer = ids.first { $0 != first && $0 != second }!
        let afterName = Policy.colorOrder(existing: afterNo, claims: [newcomer, first, second])
        let colors = VoicePrintStyle.colorIndices(for: afterName)
        assertEqual(colors[first], startColors[first])
        assertEqual(colors[second], startColors[second])
        assertFalse([startColors[first], startColors[second]].contains(colors[newcomer]), "a newcomer gets a color nobody on screen has")
    }
}
