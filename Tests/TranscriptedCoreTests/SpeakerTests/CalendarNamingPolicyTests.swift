import XCTest
@testable import TranscriptedCore

/// Promises for calendar naming (`SpeakerNamingPolicy.InviteeBars`): a voice whose
/// best match is someone on the meeting's calendar invite may be named silently
/// sooner, but only then. Everything else keeps today's bars.
@available(macOS 14.0, *)
final class CalendarNamingPolicyTests: XCTestCase {

    private func person(_ name: String, confirmedMeetings: Int) -> SpeakerProfile {
        SpeakerProfile(
            id: UUID(),
            displayName: name,
            nameSource: NameSource.userManual,
            embedding: [1, 0, 0],
            firstSeen: Date(),
            lastSeen: Date(),
            callCount: confirmedMeetings,
            confidence: 0.9,
            disputeCount: 0,
            confirmedMeetingCount: confirmedMeetings
        )
    }

    private func autoAccept(_ profile: SpeakerProfile, similarity: Double, runnerUp: Double, invited: [String]) -> Bool {
        let keys = Set(invited.map(SpeakerNamingPolicy.nameKey))
        return SpeakerNamingPolicy.shouldAutoAccept(
            profile: profile,
            similarity: similarity,
            secondBestSimilarity: runnerUp,
            recentOutcomes: [],
            inviteeBars: SpeakerNamingPolicy.inviteeBars(for: profile, invitedNameKeys: keys)
        )
    }

    private func autoAcceptOnRecentLineup(_ profile: SpeakerProfile, similarity: Double, runnerUp: Double) -> Bool {
        SpeakerNamingPolicy.shouldAutoAccept(
            profile: profile,
            similarity: similarity,
            secondBestSimilarity: runnerUp,
            recentOutcomes: [],
            inviteeBars: SpeakerNamingPolicy.inviteeBars(
                for: profile,
                invitedNameKeys: [SpeakerNamingPolicy.nameKey(profile.displayName ?? "")],
                lineupIsFromInvite: false
            )
        )
    }

    func testWithNoInviteALoneMatchBelowTheStandardBarGoesToReview() {
        // A stranger who sounds a bit like one recent colleague, and nobody
        // else came close: not enough to put a name on them silently.
        let taylor = person("Taylor Wolf", confirmedMeetings: 2)
        XCTAssertFalse(autoAcceptOnRecentLineup(taylor, similarity: 0.84, runnerUp: -1))
    }

    func testWithNoInviteALoneMatchAtTheStandardBarIsStillNamedSilently() {
        let taylor = person("Taylor Wolf", confirmedMeetings: 2)
        XCTAssertTrue(autoAcceptOnRecentLineup(taylor, similarity: 0.95, runnerUp: -1))
    }

    func testWithNoInviteAClearWinnerOverAnotherSavedPersonIsNamedSilently() {
        let taylor = person("Taylor Wolf", confirmedMeetings: 2)
        XCTAssertTrue(autoAcceptOnRecentLineup(taylor, similarity: 0.86, runnerUp: 0.70))
    }

    func testWithAnInviteALoneMatchKeepsTheLabTunedBar() {
        let taylor = person("Taylor Wolf", confirmedMeetings: 2)
        XCTAssertTrue(autoAccept(taylor, similarity: 0.84, runnerUp: -1, invited: ["Taylor Wolf"]))
    }

    func testOnlyARealInviteCountsAsAnInviteLineup() {
        XCTAssertTrue(SpeakerNamingPolicy.lineupIsFromInvite(.init(invitedNames: ["Sam Lee"])))
        XCTAssertFalse(SpeakerNamingPolicy.lineupIsFromInvite(.init(invitedNames: [])))
        XCTAssertFalse(SpeakerNamingPolicy.lineupIsFromInvite(.init(invitedNames: ["  "])))
    }

    func testAnInvitedPersonConfirmedTwiceIsNamedSilentlyOnAClearMatch() {
        let sam = person("Sam Lee", confirmedMeetings: 2)
        XCTAssertTrue(autoAccept(sam, similarity: 0.84, runnerUp: 0.40, invited: ["Sam Lee", "Grace Kim"]))
    }

    func testThePersonIsNotNamedSilentlyWhenTheyWerentInvited() {
        let sam = person("Sam Lee", confirmedMeetings: 2)
        XCTAssertFalse(autoAccept(sam, similarity: 0.84, runnerUp: 0.40, invited: ["Grace Kim"]))
    }

    func testWithNoInviteTodaysFiveMeetingRuleStillApplies() {
        XCTAssertFalse(autoAccept(person("Sam Lee", confirmedMeetings: 4), similarity: 0.95, runnerUp: 0.40, invited: []))
        XCTAssertTrue(autoAccept(person("Sam Lee", confirmedMeetings: 5), similarity: 0.95, runnerUp: 0.40, invited: []))
    }

    func testAnInvitedPersonConfirmedOnceStillGoesToReview() {
        XCTAssertFalse(autoAccept(person("Sam Lee", confirmedMeetings: 1), similarity: 0.95, runnerUp: 0.40, invited: ["Sam Lee"]))
    }

    func testALookAlikeTooCloseInSimilarityStillBlocksSilentNamingForInvitees() {
        // Clear of the 0.80 bar, but the runner-up is within the 0.10 margin.
        XCTAssertFalse(autoAccept(person("Sam Lee", confirmedMeetings: 3), similarity: 0.86, runnerUp: 0.80, invited: ["Sam Lee"]))
    }

    func testAWeakMatchIsNotNamedSilentlyEvenForAnInvitee() {
        XCTAssertFalse(autoAccept(person("Sam Lee", confirmedMeetings: 3), similarity: 0.78, runnerUp: 0.30, invited: ["Sam Lee"]))
    }

    func testInviteNamesMatchIgnoringCaseAndSpacing() {
        let sam = person("Sam  Lee", confirmedMeetings: 2)
        XCTAssertNotNil(SpeakerNamingPolicy.inviteeBars(for: sam, invitedNameKeys: [SpeakerNamingPolicy.nameKey(" sam lee ")]))
    }

    func testAnUnnamedVoiceNeverGetsInviteeBars() {
        var unnamed = person("x", confirmedMeetings: 3)
        unnamed.displayName = nil
        XCTAssertNil(SpeakerNamingPolicy.inviteeBars(for: unnamed, invitedNameKeys: [SpeakerNamingPolicy.nameKey("x")]))
    }

    func testTheInitialMappingNamesAnInvitedPersonTheSameWayTheGateDoes() {
        let sam = person("Sam Lee", confirmedMeetings: 2)
        let bars = SpeakerNamingPolicy.inviteeBars(for: sam, invitedNameKeys: [SpeakerNamingPolicy.nameKey("Sam Lee")])
        let mapping = SpeakerNamingPolicy.initialMapping(
            speakerId: "1", profile: sam, similarity: 0.84, secondBestSimilarity: 0.40, inviteeBars: bars
        )
        XCTAssertEqual(mapping.identifiedName, "Sam Lee")
        let withoutInvite = SpeakerNamingPolicy.initialMapping(
            speakerId: "1", profile: sam, similarity: 0.84, secondBestSimilarity: 0.40
        )
        XCTAssertNil(withoutInvite.identifiedName)
    }
}

/// Promises for the lineup behind lineup naming: the calendar invite when there is
/// one, else the people heard most recently (random Zooms with no invite).
@available(macOS 14.0, *)
final class LineupNamingTests: XCTestCase {
    private func person(_ name: String?, confirmed: Int, lastSeenDaysAgo: Double) -> SpeakerProfile {
        SpeakerProfile(
            id: UUID(), displayName: name, nameSource: NameSource.userManual, embedding: [1, 0, 0],
            firstSeen: Date(timeIntervalSinceNow: -86_400 * 90),
            lastSeen: Date(timeIntervalSinceNow: -86_400 * lastSeenDaysAgo),
            callCount: confirmed, confidence: 0.9, disputeCount: 0, confirmedMeetingCount: confirmed
        )
    }

    func testAnInviteWinsOverRecentPeople() {
        let profiles = [person("Sam Lee", confirmed: 3, lastSeenDaysAgo: 1)]
        let keys = SpeakerNamingPolicy.lineupNameKeys(.init(invitedNames: ["Grace Kim"]), profilesBeforeMeeting: profiles)
        XCTAssertEqual(keys, [SpeakerNamingPolicy.nameKey("Grace Kim")])
    }

    func testWithNoInviteTheMostRecentlyHeardPeopleFormTheLineup() {
        let profiles = [
            person("Old Friend", confirmed: 3, lastSeenDaysAgo: 30),
            person("Sam Lee", confirmed: 3, lastSeenDaysAgo: 1),
            person("Grace Kim", confirmed: 2, lastSeenDaysAgo: 2),
        ]
        let keys = SpeakerNamingPolicy.lineupNameKeys(.init(invitedNames: [], recentPeopleLimit: 2), profilesBeforeMeeting: profiles)
        XCTAssertEqual(keys, Set(["Sam Lee", "Grace Kim"].map(SpeakerNamingPolicy.nameKey)))
    }

    func testUnnamedOrNeverConfirmedVoicesAreNeverOnTheLineup() {
        let profiles = [
            person(nil, confirmed: 3, lastSeenDaysAgo: 0),
            person("Pat Doe", confirmed: 0, lastSeenDaysAgo: 0),
            person("Sam Lee", confirmed: 1, lastSeenDaysAgo: 5),
        ]
        let keys = SpeakerNamingPolicy.lineupNameKeys(.init(invitedNames: []), profilesBeforeMeeting: profiles)
        XCTAssertEqual(keys, [SpeakerNamingPolicy.nameKey("Sam Lee")])
    }

    func testTurningTheFallbackOffLeavesNoLineupWithoutAnInvite() {
        let profiles = [person("Sam Lee", confirmed: 3, lastSeenDaysAgo: 1)]
        let keys = SpeakerNamingPolicy.lineupNameKeys(.init(invitedNames: [], recentPeopleLimit: 0), profilesBeforeMeeting: profiles)
        XCTAssertTrue(keys.isEmpty)
    }
}
