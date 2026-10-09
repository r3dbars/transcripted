import XCTest
@testable import TranscriptedCore

/// Promise: every review row about a saved, named person (asked or recognized)
/// carries their confirmed-meeting count, the bar this meeting's silent-naming
/// gate uses for them, and whether they're trusted, so the review can show their
/// New / Learning / Auto dial. A row that asks for a name carries nothing.
@available(macOS 14.0, *)
final class SpeakerNamingConfirmationProgressTests: XCTestCase {
    private var tempDirectory: URL!
    private var database: SpeakerDatabase!

    override func setUpWithError() throws {
        tempDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("SpeakerNamingConfirmationProgressTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tempDirectory, withIntermediateDirectories: true)
        database = SpeakerDatabase(path: tempDirectory.appendingPathComponent("speakers.sqlite").path)
    }

    override func tearDownWithError() throws {
        database = nil
        if let tempDirectory { try? FileManager.default.removeItem(at: tempDirectory) }
        tempDirectory = nil
    }

    func testConfirmRowShowsCountAgainstTheStandardBarWithoutALineup() throws {
        let maya = try person("Maya Patel", confirmedMeetings: 2)
        let entry = progress(for: [askAbout(maya, name: "Maya Patel")]).first
        XCTAssertEqual(
            entry?.confirmationProgress,
            SpeakerNamingConfirmationProgress(confirmedMeetings: 2, requiredMeetings: SpeakerNamingPolicy.requiredConfirmedMeetings)
        )
    }

    func testLineupMeetingUsesTheLowerLineupBar() throws {
        let maya = try person("Maya Patel", confirmedMeetings: 1)
        let entry = progress(
            for: [askAbout(maya, name: "Maya Patel")],
            invited: [SpeakerNamingPolicy.nameKey("Maya Patel")]
        ).first
        let lineupBar = try XCTUnwrap(SpeakerNamingPolicy.inviteeBars(
            for: try XCTUnwrap(database.getSpeaker(id: maya)),
            invitedNameKeys: [SpeakerNamingPolicy.nameKey("Maya Patel")],
            thresholds: .weSpeaker
        )).requiredConfirmedMeetings
        XCTAssertLessThan(lineupBar, SpeakerNamingPolicy.requiredConfirmedMeetings)
        XCTAssertEqual(entry?.confirmationProgress, SpeakerNamingConfirmationProgress(confirmedMeetings: 1, requiredMeetings: lineupBar))
    }

    func testAtTheBarShowsAutoAndNameRowsShowNothing() throws {
        let done = try person("Sam Lee", confirmedMeetings: SpeakerNamingPolicy.requiredConfirmedMeetings)
        let unknown = try person("Ignored", confirmedMeetings: 0)
        let entries = progress(for: [
            askAbout(done, name: "Sam Lee"),
            SpeakerNamingEntry(
                id: unknown, diarizerSpeakerId: "2", clipURL: tempDirectory.appendingPathComponent("b.wav"),
                sampleText: "Hi.", currentName: nil, matchSimilarity: nil, needsNaming: true, needsConfirmation: false
            ),
        ])
        XCTAssertEqual(entries[0].confirmationProgress?.tier, .auto, "past the bar, a weak match still asks, but the person is on Auto")
        XCTAssertNil(entries[1].confirmationProgress, "a name box has no one to count")
    }

    func testRecognizedRowsCarryProgressAndCorrectionsDropToLearning() throws {
        let priya = try person("Priya Shah", confirmedMeetings: 7)
        var recognizedRow = askAbout(priya, name: "Priya Shah")
        recognizedRow = SpeakerNamingEntry(
            id: recognizedRow.id, diarizerSpeakerId: "1", clipURL: recognizedRow.clipURL,
            sampleText: "Hi.", currentName: "Priya Shah", matchSimilarity: 0.97, needsNaming: false, needsConfirmation: false
        )
        let trusted = TranscriptionTaskManager.withConfirmationProgress(
            [recognizedRow], recognized: true, profile: { self.database.getSpeaker(id: $0) },
            invited: [], fromInvite: false, thresholds: .weSpeaker
        ).first
        XCTAssertEqual(trusted?.confirmationProgress,
                       SpeakerNamingConfirmationProgress(confirmedMeetings: 7, requiredMeetings: 5, isTrusted: true))
        XCTAssertEqual(trusted?.confirmationProgress?.tier, .auto)
        XCTAssertNil(TranscriptionTaskManager.withConfirmationProgress(
            [recognizedRow], profile: { self.database.getSpeaker(id: $0) },
            invited: [], fromInvite: false, thresholds: .weSpeaker
        ).first?.confirmationProgress, "recognized rows only get progress when asked for")

        let probation = TranscriptionTaskManager.withConfirmationProgress(
            [recognizedRow], recognized: true, profile: { self.database.getSpeaker(id: $0) }, trusted: { _ in false },
            invited: [], fromInvite: false, thresholds: .weSpeaker
        ).first
        XCTAssertEqual(probation?.confirmationProgress?.tier, .learning, "a corrected person never shows Auto")
    }

    func testTierRule() {
        XCTAssertEqual(SpeakerNamingTier.tier(confirmedMeetings: 0, requiredMeetings: 5, isTrusted: true), .new)
        XCTAssertEqual(SpeakerNamingTier.tier(confirmedMeetings: 1, requiredMeetings: 5, isTrusted: true), .new)
        XCTAssertEqual(SpeakerNamingTier.tier(confirmedMeetings: 2, requiredMeetings: 5, isTrusted: true), .learning)
        XCTAssertEqual(SpeakerNamingTier.tier(confirmedMeetings: 4, requiredMeetings: 5, isTrusted: true), .learning)
        XCTAssertEqual(SpeakerNamingTier.tier(confirmedMeetings: 5, requiredMeetings: 5, isTrusted: true), .auto)
        XCTAssertEqual(SpeakerNamingTier.tier(confirmedMeetings: 9, requiredMeetings: 5, isTrusted: false), .learning)
        XCTAssertEqual(SpeakerNamingTier.tier(confirmedMeetings: 1, requiredMeetings: 5, isTrusted: false), .new)
        // Lineup bar: 2 meetings is enough on a live meeting with the person on the lineup.
        XCTAssertEqual(SpeakerNamingTier.tier(confirmedMeetings: 2, requiredMeetings: 2, isTrusted: true), .auto)
        XCTAssertEqual(SpeakerNamingTier.tier(confirmedMeetings: 1, requiredMeetings: 2, isTrusted: true), .new)
        // A bar of 0 never makes an unconfirmed person Auto.
        XCTAssertEqual(SpeakerNamingTier.tier(confirmedMeetings: 0, requiredMeetings: 0, isTrusted: true), .new)
    }

    // MARK: - Helpers

    func testRepeatedImportDoesNotEarnAnotherRingButANewRecordingDoes() throws {
        let maya = try person("Maya Patel", confirmedMeetings: 3)
        let original = UUID()
        let recording = SpeakerConfirmationMeetingID.forImportedContent(key: "same-audio")
        try database.recordConfirmationMeetingAlias(transcriptId: original, meetingId: recording)
        try database.recordUserConfirmations([SpeakerUserConfirmation(profileId: maya, transcriptId: original, kind: .confirmed)])
        let repeated = UUID()
        // The review is prepared before the repeated import's alias is saved.
        XCTAssertFalse(try database.confirmationWouldIncreaseCount(profileId: maya, transcriptId: repeated, meetingId: recording))
        let eligibility = try TranscriptionTaskManager.confirmationEligibility(profiles: database.allSpeakers(),
            store: database, transcriptId: repeated, meetingId: recording)
        let entries = TranscriptionTaskManager.withConfirmationProgress(
            [askAbout(maya, name: "Maya Patel")], profile: { self.database.getSpeaker(id: $0) },
            earnsConfirmation: { eligibility[$0] ?? false },
            invited: [], fromInvite: false, thresholds: .weSpeaker)
        XCTAssertEqual(entries.first?.confirmationProgress?.confirmedMeetings, 4)
        XCTAssertEqual(entries.first?.confirmationProgress?.earnsConfirmation, false)
        // Once persisted, alias resolution also works for later review/retranscription.
        try database.recordConfirmationMeetingAlias(transcriptId: repeated, meetingId: recording)
        XCTAssertFalse(try database.confirmationWouldIncreaseCount(profileId: maya, transcriptId: repeated))
        XCTAssertTrue(try database.confirmationWouldIncreaseCount(profileId: maya, transcriptId: UUID()))
        XCTAssertTrue(try database.confirmationWouldIncreaseCount(profileId: maya, transcriptId: UUID(),
            meetingId: SpeakerConfirmationMeetingID.forImportedContent(key: "different-audio")))
    }

    func testSelectedSavedPersonChecksThatPersonsRecordingLedger() throws {
        let maya = try person("Maya Patel", confirmedMeetings: 3)
        let meeting = UUID()
        try database.recordUserConfirmations([SpeakerUserConfirmation(profileId: maya, transcriptId: meeting, kind: .confirmed)])
        let other = database.addOrUpdateSpeaker(embedding: [0, 1], existingId: nil).id
        XCTAssertFalse(try database.confirmationWouldIncreaseCount(profileId: maya, transcriptId: meeting))
        XCTAssertTrue(try database.confirmationWouldIncreaseCount(profileId: other, transcriptId: meeting),
                      "another person's confirmation does not suppress the selected person's first yes")
    }

    private func person(_ name: String, confirmedMeetings: Int) throws -> UUID {
        let id = database.addOrUpdateSpeaker(embedding: [1, 0], existingId: nil).id
        database.setDisplayName(id: id, name: name, source: NameSource.userManual)
        try database.recordUserConfirmations((0..<confirmedMeetings).map { _ in
            SpeakerUserConfirmation(profileId: id, transcriptId: UUID(), kind: .confirmed)
        })
        return id
    }

    private func askAbout(_ id: UUID, name: String) -> SpeakerNamingEntry {
        SpeakerNamingEntry(
            id: id, diarizerSpeakerId: "1", clipURL: tempDirectory.appendingPathComponent("a.wav"),
            sampleText: "Hi.", currentName: name, matchSimilarity: 0.8, needsNaming: false, needsConfirmation: true
        )
    }

    private func progress(for entries: [SpeakerNamingEntry], invited: Set<String> = []) -> [SpeakerNamingEntry] {
        TranscriptionTaskManager.withConfirmationProgress(
            entries,
            profile: { self.database.getSpeaker(id: $0) },
            invited: invited,
            fromInvite: true,
            thresholds: .weSpeaker
        )
    }
}
