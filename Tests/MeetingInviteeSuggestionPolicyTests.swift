import Foundation

func testMeetingInviteeSuggestionPolicy() {
    let start = Date(timeIntervalSince1970: 1_800_000_000)

    func event(
        from offsetMinutes: Double,
        minutes: Double,
        names: [String],
        allDay: Bool = false
    ) -> MeetingInviteeEventSnapshot {
        let eventStart = start.addingTimeInterval(offsetMinutes * 60)
        return MeetingInviteeEventSnapshot(
            startDate: eventStart,
            endDate: eventStart.addingTimeInterval(minutes * 60),
            isAllDay: allDay,
            inviteeNames: names
        )
    }

    func match(startedMinutesIntoEvent minutes: Double, _ events: [MeetingInviteeEventSnapshot]) -> MeetingInviteeEventSnapshot? {
        MeetingInviteeSuggestionPolicy.matchingEvent(
            recordingStart: start.addingTimeInterval(minutes * 60),
            among: events
        )
    }

    runSuite("MeetingInviteeSuggestionPolicy matches a recording that starts with the event") {
        let hour = event(from: 0, minutes: 60, names: ["Sam Lee", "Priya Shah"])
        assertEqual(match(startedMinutesIntoEvent: 0, [hour]), hour, "starting right on time should match")
        assertEqual(match(startedMinutesIntoEvent: -0.5, [hour]), hour, "starting a few seconds early, like from the pop-up, should match")
        assertEqual(match(startedMinutesIntoEvent: 4, [hour]), hour, "starting a few minutes late should still match")
    }

    runSuite("MeetingInviteeSuggestionPolicy ignores a later call inside a long calendar slot") {
        let hour = event(from: 0, minutes: 60, names: ["Sam Lee", "Priya Shah"])
        assertNil(
            match(startedMinutesIntoEvent: 30, [hour]),
            "an hour-long meeting that ended early must not name a different call later in that hour"
        )
        assertNil(match(startedMinutesIntoEvent: 6, [hour]), "past the pop-up's grace window is too late to be sure")
        assertNil(match(startedMinutesIntoEvent: -2, [hour]), "more than a minute early is too early to be sure")
        assertEqual(
            MeetingInviteeSuggestionPolicy.startLeadTime,
            MeetingPromptHeuristics.calendarReminderLeadTime,
            "the match window should stay the same as the record-this-meeting pop-up"
        )
        assertEqual(
            MeetingInviteeSuggestionPolicy.startGrace,
            MeetingPromptHeuristics.calendarReminderPostStartGrace,
            "the match window should stay the same as the record-this-meeting pop-up"
        )
    }

    runSuite("MeetingInviteeSuggestionPolicy ignores all-day, empty, and double-booked events") {
        let allDay = event(from: 0, minutes: 1440, names: ["Sam Lee"], allDay: true)
        let noInvitees = event(from: 0, minutes: 30, names: [])
        assertNil(match(startedMinutesIntoEvent: 0, [allDay, noInvitees]), "all-day events and events with nobody else invited should not count")

        let first = event(from: 0, minutes: 30, names: ["Sam Lee"])
        let doubleBooked = event(from: 0, minutes: 30, names: ["Jo Park"])
        assertNil(match(startedMinutesIntoEvent: 1, [first, doubleBooked]), "a double booking with different people should suggest nobody")

        let sameInviteCopy = event(from: 0, minutes: 30, names: ["Sam Lee"])
        assertEqual(match(startedMinutesIntoEvent: 1, [first, sameInviteCopy]), first, "the same invite on two calendars is still one meeting")

        let earlier = event(from: -30, minutes: 60, names: ["Jo Park"])
        assertEqual(
            match(startedMinutesIntoEvent: 0, [earlier, first]),
            first,
            "a longer event still running from earlier should not block the one that just started"
        )
    }

    runSuite("MeetingInviteeSuggestionPolicy cleans invitee names") {
        let names = MeetingInviteeSuggestionPolicy.inviteeNames(from: [
            MeetingInviteeRawParticipant(name: "Justin", email: "mailto:me@example.com", isCurrentUser: true, isPerson: true),
            MeetingInviteeRawParticipant(name: "Sam Lee", email: "mailto:sam@example.com", isCurrentUser: false, isPerson: true),
            MeetingInviteeRawParticipant(name: " sam lee ", email: nil, isCurrentUser: false, isPerson: true),
            MeetingInviteeRawParticipant(name: "Room 4B", email: nil, isCurrentUser: false, isPerson: false),
            MeetingInviteeRawParticipant(name: nil, email: "mailto:priya.shah@example.com", isCurrentUser: false, isPerson: true),
            MeetingInviteeRawParticipant(name: "jo@example.com", email: nil, isCurrentUser: false, isPerson: true),
            MeetingInviteeRawParticipant(name: nil, email: "mailto:jbetker91@example.com", isCurrentUser: false, isPerson: true),
            MeetingInviteeRawParticipant(name: "You", email: nil, isCurrentUser: false, isPerson: true),
        ])
        assertEqual(
            names,
            ["Sam Lee", "Priya Shah"],
            "you, rooms, duplicates, the owner label and email-only invitees without a readable name should be left out"
        )
    }

    runSuite("MeetingInviteeSuggestionPolicy maps invitees onto saved people") {
        let sam = makeInviteeTestPerson(name: "Sam Lee", calls: 3)
        let taylorA = makeInviteeTestPerson(name: "Taylor Wolfe", calls: 2)
        let taylorB = makeInviteeTestPerson(name: "Taylor Wolfe", calls: 1)
        let identity = SpeakerNameSelectionPolicy.makeIdentityLabels(
            for: [sam, taylorA, taylorB],
            id: { $0.id },
            displayName: { $0.displayName },
            callCount: { $0.callCount }
        )
        let labels = MeetingInviteeSuggestionPolicy.suggestionLabels(
            inviteeNames: ["sam lee", "Taylor Wolfe", "Priya Shah", "Sam Lee"],
            labels: identity.labels,
            optionsByLabel: identity.lookup,
            displayName: { $0.displayName }
        )
        assertEqual(
            labels,
            ["Sam Lee", "Taylor Wolfe", "Priya Shah"],
            "a unique saved person keeps their label; an ambiguous or new name stays as typed, once"
        )
    }

    runSuite("MeetingInviteeSuggestionPolicy caps the name buttons") {
        let labels = MeetingInviteeSuggestionPolicy.suggestionLabels(
            inviteeNames: ["A One", "B Two", "C Three", "D Four", "E Five"],
            labels: [String](),
            optionsByLabel: [String: SpeakerIdentityOption](),
            displayName: { $0.displayName }
        )
        assertEqual(labels.count, MeetingInviteeSuggestionPolicy.maxSuggestions, "a big invite should not flood the row")
    }

    runSuite("MeetingInviteeSuggestionPolicy puts invitees first, after You") {
        assertEqual(
            MeetingInviteeSuggestionPolicy.labelsWithInviteesFirst(
                labels: ["You", "Alex", "Sam Lee", "Zoe"],
                inviteeLabels: ["Sam Lee", "Priya Shah"]
            ),
            ["You", "Sam Lee", "Priya Shah", "Alex", "Zoe"],
            "the local mic list keeps You on top, then the invitees"
        )
        assertEqual(
            MeetingInviteeSuggestionPolicy.labelsWithInviteesFirst(labels: ["Alex", "Sam Lee"], inviteeLabels: ["Sam Lee"]),
            ["Sam Lee", "Alex"],
            "a remote list leads with the invitees"
        )
    }

    runSuite("MeetingInviteeSuggestionPolicy pre-fills only a clear 1:1") {
        func prefill(invitees: [String], voices: Int?, rows: Int, suggested: Bool = false) -> String? {
            MeetingInviteeSuggestionPolicy.oneOnOnePrefill(
                inviteeNames: invitees,
                remoteVoicesInMeeting: voices,
                remoteRowsInReview: rows,
                remoteRowHasSuggestion: suggested
            )
        }
        assertEqual(prefill(invitees: ["Sam Lee"], voices: 1, rows: 1), "Sam Lee", "one other invitee and one unnamed remote voice is a 1:1")
        assertNil(prefill(invitees: ["Sam Lee", "Priya Shah"], voices: 1, rows: 1), "two invitees is not a 1:1")
        assertNil(prefill(invitees: ["Sam Lee"], voices: 2, rows: 2), "two remote voices is not a 1:1")
        assertNil(
            prefill(invitees: ["Sam Lee"], voices: 2, rows: 1),
            "if Sam was already named silently, the one extra guest left in review must not be handed Sam's name"
        )
        assertNil(prefill(invitees: ["Sam Lee"], voices: nil, rows: 1), "an unknown voice count should not pre-fill")
        assertNil(prefill(invitees: ["Sam Lee"], voices: 1, rows: 1, suggested: true), "a voice the matcher already suggested a name for keeps its suggestion")
    }
}

private func makeInviteeTestPerson(name: String, calls: Int) -> SpeakerIdentityOption {
    SpeakerIdentityOption(id: UUID(), displayName: name, callCount: calls)
}
