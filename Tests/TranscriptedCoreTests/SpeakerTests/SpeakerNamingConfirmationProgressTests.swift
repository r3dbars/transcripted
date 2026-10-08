import XCTest
@testable import TranscriptedCore

/// Promise: an "Is this …?" row carries the person's confirmed-meeting count
/// and the bar this meeting's silent-naming gate uses for them, so the review
/// can say how close they are. Nothing is attached once they're at the bar or
/// when the row asks for a name.
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

    func testNoProgressAtTheBarOrOnNameRows() throws {
        let done = try person("Sam Lee", confirmedMeetings: SpeakerNamingPolicy.requiredConfirmedMeetings)
        let unknown = try person("Ignored", confirmedMeetings: 0)
        let entries = progress(for: [
            askAbout(done, name: "Sam Lee"),
            SpeakerNamingEntry(
                id: unknown, diarizerSpeakerId: "2", clipURL: tempDirectory.appendingPathComponent("b.wav"),
                sampleText: "Hi.", currentName: nil, matchSimilarity: nil, needsNaming: true, needsConfirmation: false
            ),
        ])
        XCTAssertNil(entries[0].confirmationProgress, "someone already at the bar shows nothing")
        XCTAssertNil(entries[1].confirmationProgress, "a name box has no one to count")
    }

    // MARK: - Helpers

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
