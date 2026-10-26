import Foundation

// Promises for Settings › Speakers' "Who spoke?" cards, one meeting at a time:
// what the page says around a card, what a likely name is, what the island's
// answers save as, and how Done, Undo, Skip and a jump from Meetings move the
// visit along.
func testSpeakerMeetingReview() {
    typealias Policy = SpeakerMeetingReviewPolicy

    runSuite("The headline counts voices in plain words and disappears when none are left") {
        assertEqual(Policy.headline(voiceCount: 12), "12 voices from your meetings need a name")
        assertEqual(Policy.headline(voiceCount: 1), "1 voice from your meetings needs a name")
        assertNil(Policy.headline(voiceCount: 0), "nothing to name, no headline")
    }

    runSuite("Meeting N of M counts the meetings done this visit plus the ones left") {
        let first = Policy.position(meetingsDone: 0, meetingsLeft: 8)
        assertEqual(first, .init(current: 1, total: 8))
        assertEqual(first.map(Policy.positionLine), "Meeting 1 of 8")

        let third = Policy.position(meetingsDone: 2, meetingsLeft: 6)
        assertEqual(third.map(Policy.positionLine), "Meeting 3 of 8", "finishing a meeting moves along without changing the total")
        assertNil(Policy.position(meetingsDone: 3, meetingsLeft: 0), "with no card up there's no position")
    }

    runSuite("The bar lights the meetings done and the one on the card, and never grows past twelve segments") {
        assertEqual(Policy.progress(.init(current: 1, total: 8)), .init(segments: 8, lit: 1))
        assertEqual(Policy.progress(.init(current: 8, total: 8)), .init(segments: 8, lit: 8))
        let long = Policy.progress(.init(current: 1, total: 40))
        assertEqual(long.segments, 12, "forty meetings still draw twelve segments")
        assertEqual(long.lit, 1, "the first meeting lights one")
        assertEqual(Policy.progress(.init(current: 40, total: 40)).lit, 12, "the last meeting lights all of them")
    }

    runSuite("The card says whose meeting it is and where Done goes") {
        assertEqual(Policy.cardTitle(meetingTitle: "Weekly sync"), "Who spoke? \u{00B7} Weekly sync")
        assertEqual(Policy.cardTitle(meetingTitle: "  "), "Who spoke?")
        assertEqual(Policy.doneTitle(meetingsAfterThis: 3), "Done, next meeting")
        assertEqual(Policy.doneTitle(meetingsAfterThis: 0), "Done", "the last meeting has no next one")
        assertEqual(Policy.doneDetail(names: ["Marcus Reed", "Sam Ortiz"]), "Marcus Reed, Sam Ortiz. Saving in a moment.")
        assertEqual(Policy.doneDetail(names: ["A", "B", "C", "D", "E"]), "A, B, C and 2 more. Saving in a moment.")
        assertEqual(Policy.rowPill(voicesToName: 2), "2 to name")
        assertNil(Policy.rowPill(voicesToName: 0))
        assertEqual(HomeRowMenuPolicy.whoSpokeTitle(voicesToName: 2), "Who spoke? \u{00B7} 2 to name")
        assertEqual(HomeRowMenuPolicy.whoSpokeTitle(voicesToName: 0), "Who spoke?")
    }

    runSuite("A likely name is the closest saved person whose voice matches, never someone unnamed or You") {
        let voice = makeReviewProfile(name: nil)
        let marcus = makeReviewProfile(name: "Marcus Reed")
        let dana = makeReviewProfile(name: "Dana Holt")
        let other = makeReviewProfile(name: nil)
        let you = makeReviewProfile(name: "You")
        let candidates = [
            SpeakerDuplicateCandidate(source: voice, target: marcus, reason: .voiceMatch, voiceSimilarity: 0.71),
            SpeakerDuplicateCandidate(source: dana, target: voice, reason: .voiceMatch, voiceSimilarity: 0.84),
            SpeakerDuplicateCandidate(source: voice, target: other, reason: .voiceMatch, voiceSimilarity: 0.95),
            SpeakerDuplicateCandidate(source: voice, target: you, reason: .voiceMatch, voiceSimilarity: 0.99),
        ]
        let guess = Policy.guess(for: voice.id, among: candidates)
        assertEqual(guess?.person.id, dana.id, "the closer of the two named matches, whichever side of the pair it's on")
        assertEqual(guess?.similarity, 0.84)

        let nameOnly = [SpeakerDuplicateCandidate(source: voice, target: marcus, reason: .sameName, voiceSimilarity: nil)]
        assertNil(Policy.guess(for: voice.id, among: nameOnly), "a name match without a voice match is no guess")
        assertNil(Policy.guess(for: UUID(), among: candidates), "a voice in no pair has no guess")
    }

    runSuite("The island's answers become one save per voice") {
        let typed = UUID(), confirmed = UUID(), mine = UUID(), noise = UUID(), saved = UUID(), you = UUID()
        let dana = UUID()
        let steps = Policy.steps(for: [
            update(typed, "Rosa Diaz", .named),
            update(confirmed, "Dana Holt", .merged(targetProfileId: dana)),
            update(mine, "You", .collapsedToMe),
            update(noise, "Speaker 3", .discardedFromDatabase),
            update(saved, "Sam Ortiz", .confirmed),
            update(you, "You", .named),
            update(typed, "Someone else", .named),
        ])
        assertEqual(steps, [
            .name(voiceID: typed, name: "Rosa Diaz"),
            .join(voiceID: confirmed, personID: dana, name: "Dana Holt"),
            .markAsMe(voiceID: mine),
            .notAPerson(voiceID: noise),
            .name(voiceID: saved, name: "Sam Ortiz"),
            .markAsMe(voiceID: you),
        ], "typed names save as names, ✓ joins the person, All me and Me are you, Not a person deletes; one answer per voice")
        assertEqual(Policy.namedCount(steps), 5, "Not a person doesn't count as named")
        assertEqual(steps.compactMap(\.savedName), ["Rosa Diaz", "Dana Holt", "You", "Sam Ortiz", "You"])
    }

    runSuite("Done holds a card for Undo, the next Done saves it, and Undo puts it back on top") {
        var state = SpeakerMeetingReviewState()
        let weekly = finished("weekly")
        assertNil(state.finish(weekly), "nothing was waiting before the first Done")
        assertEqual(state.meetingsDone, 1)
        assertEqual(state.heldOutCallKeys, ["weekly"], "the finished card stays off the stack while it can be undone")

        let design = finished("design")
        assertEqual(state.finish(design)?.callKey, "weekly", "finishing the next card hands back the one to save now")
        assertEqual(state.heldOutCallKeys, ["weekly", "design"], "a card saving stays off the stack too")
        assertEqual(state.meetingsDone, 2)

        assertNil(state.undo(token: weekly.token), "only the card on the banner can be undone")
        assertEqual(state.undo(token: design.token)?.callKey, "design")
        assertEqual(state.meetingsDone, 1, "Undo takes the meeting back off the count")
        assertEqual(state.focusedCallKey, "design", "the undone card comes back on top")
        assertEqual(state.heldOutCallKeys, ["weekly"])

        state.saved(callKey: "weekly")
        assertTrue(state.heldOutCallKeys.isEmpty, "once its saves finish the queue decides what's left")
    }

    runSuite("A finished card saves when its time runs out, once") {
        var state = SpeakerMeetingReviewState()
        let weekly = finished("weekly")
        _ = state.finish(weekly)
        assertNil(state.startSaving(token: UUID()), "a stale timer saves nothing")
        assertEqual(state.startSaving(token: weekly.token)?.callKey, "weekly")
        assertNil(state.finished, "the banner goes away when it saves")
        assertNil(state.startSaving(token: weekly.token), "it can't save twice")
        assertNil(state.undo(token: weekly.token), "and can't be undone once saving")
        assertEqual(state.heldOutCallKeys, ["weekly"])
    }

    runSuite("Skip and a jump from Meetings move the visit along") {
        var state = SpeakerMeetingReviewState()
        state.focus("retro")
        assertEqual(state.focusedCallKey, "retro")
        state.skipped(callKey: "retro")
        assertEqual(state.meetingsDone, 1, "a skipped meeting counts as done for this visit")
        assertNil(state.focusedCallKey, "the jump is used up once that card is answered")
        assertEqual(state.heldOutCallKeys, ["retro"], "a skipped card stays off the stack while its answers save")
        state.saved(callKey: "retro")

        state.resetProgressIfIdle(meetingsLeft: 2)
        assertEqual(state.meetingsDone, 1, "progress stays while meetings are left")
        state.resetProgressIfIdle(meetingsLeft: 0)
        assertEqual(state.meetingsDone, 0, "with nothing left the next visit starts at Meeting 1")

        _ = state.finish(finished("weekly"))
        state.resetProgressIfIdle(meetingsLeft: 0)
        assertEqual(state.meetingsDone, 1, "not while a finished card can still be undone")
    }

    runSuite("A Skip whose answers don't save isn't a skip: the card comes back and says so") {
        var state = SpeakerMeetingReviewState()
        state.skipped(callKey: "standup")
        state.skipFailed(callKey: "standup")
        assertTrue(state.heldOutCallKeys.isEmpty, "the card goes back on the stack")
        assertEqual(state.meetingsDone, 0, "and doesn't count as done")
        state.skipFailed(callKey: "standup")
        assertEqual(state.meetingsDone, 0, "a second report changes nothing")

        assertEqual(
            Policy.saveFailedLine(meetingTitle: "Standup", failed: 1),
            "Couldn't save 1 name from Standup. Its card is back so you can try again."
        )
        assertEqual(
            Policy.saveFailedLine(meetingTitle: "", failed: 2),
            "Couldn't save 2 names. Its card is back so you can try again."
        )
    }
}

private func finished(_ key: String) -> SpeakerMeetingReviewState.Finished {
    .init(callKey: key, title: key, names: ["Rosa Diaz"], personIDs: [UUID()], token: UUID())
}

private func update(_ id: UUID, _ name: String, _ action: SpeakerReviewUpdate.NamingAction) -> SpeakerReviewUpdate {
    SpeakerReviewUpdate(persistentSpeakerId: id, diarizerSpeakerId: "1", newName: name, action: action)
}

private func makeReviewProfile(name: String?) -> SpeakerProfile {
    SpeakerProfile(
        id: UUID(),
        displayName: name,
        nameSource: name == nil ? nil : NameSource.userManual,
        embedding: [0.1, 0.2, 0.3],
        firstSeen: Date(timeIntervalSinceReferenceDate: 0),
        lastSeen: Date(timeIntervalSinceReferenceDate: 10),
        callCount: 1,
        confidence: 0.8,
        disputeCount: 0
    )
}
