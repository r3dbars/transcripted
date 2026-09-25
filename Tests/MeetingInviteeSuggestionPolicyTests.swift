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

    runSuite("MeetingInviteeSuggestionPolicy picks the event that covers the recording") {
        let standup = event(from: -2, minutes: 30, names: ["Sam Lee", "Priya Shah"])
        let later = event(from: 25, minutes: 30, names: ["Jo Park"])
        let picked = MeetingInviteeSuggestionPolicy.bestEvent(
            recordingStart: start,
            recordingDuration: 28 * 60,
            among: [later, standup]
        )
        assertEqual(picked, standup, "the event covering most of the recording should win")
    }

    runSuite("MeetingInviteeSuggestionPolicy ignores weak, all-day, empty, and tied events") {
        let barelyTouching = event(from: 20, minutes: 30, names: ["Jo Park"])
        assertNil(
            MeetingInviteeSuggestionPolicy.bestEvent(recordingStart: start, recordingDuration: 30 * 60, among: [barelyTouching]),
            "an event covering under half the recording should not count"
        )

        let allDay = event(from: -600, minutes: 1440, names: ["Sam Lee"], allDay: true)
        let noInvitees = event(from: 0, minutes: 30, names: [])
        assertNil(
            MeetingInviteeSuggestionPolicy.bestEvent(recordingStart: start, recordingDuration: 30 * 60, among: [allDay, noInvitees]),
            "all-day events and events with nobody else invited should not count"
        )

        let first = event(from: 0, minutes: 30, names: ["Sam Lee"])
        let doubleBooked = event(from: 0, minutes: 30, names: ["Jo Park"])
        assertNil(
            MeetingInviteeSuggestionPolicy.bestEvent(recordingStart: start, recordingDuration: 30 * 60, among: [first, doubleBooked]),
            "a double booking with different people should suggest nobody"
        )
    }

    runSuite("MeetingInviteeSuggestionPolicy gives very short recordings a fair window") {
        let meeting = event(from: 0, minutes: 30, names: ["Sam Lee"])
        assertEqual(
            MeetingInviteeSuggestionPolicy.bestEvent(recordingStart: start, recordingDuration: 0, among: [meeting]),
            meeting,
            "a zero-length duration should still match the event it started in"
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
        assertEqual(
            MeetingInviteeSuggestionPolicy.oneOnOnePrefill(inviteeNames: ["Sam Lee"], remoteVoiceCount: 1, remoteVoiceHasSuggestion: false),
            "Sam Lee",
            "one other invitee and one unnamed remote voice is a 1:1"
        )
        assertNil(
            MeetingInviteeSuggestionPolicy.oneOnOnePrefill(inviteeNames: ["Sam Lee", "Priya Shah"], remoteVoiceCount: 1, remoteVoiceHasSuggestion: false),
            "two invitees is not a 1:1"
        )
        assertNil(
            MeetingInviteeSuggestionPolicy.oneOnOnePrefill(inviteeNames: ["Sam Lee"], remoteVoiceCount: 2, remoteVoiceHasSuggestion: false),
            "two remote voices is not a 1:1"
        )
        assertNil(
            MeetingInviteeSuggestionPolicy.oneOnOnePrefill(inviteeNames: ["Sam Lee"], remoteVoiceCount: 1, remoteVoiceHasSuggestion: true),
            "a voice the matcher already suggested a name for keeps its suggestion"
        )
    }
}

private func makeInviteeTestPerson(name: String, calls: Int) -> SpeakerIdentityOption {
    SpeakerIdentityOption(id: UUID(), displayName: name, callCount: calls)
}
