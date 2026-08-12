import XCTest
import SQLite3
@testable import TranscriptedCore

@available(macOS 14.0, *)
final class SpeakerConfirmationTests: XCTestCase {
    private var tempDirectory: URL!
    private var database: SpeakerDatabase!

    override func setUpWithError() throws {
        tempDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("SpeakerConfirmationTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tempDirectory, withIntermediateDirectories: true)
        database = SpeakerDatabase(path: tempDirectory.appendingPathComponent("speakers.sqlite").path)
    }

    override func tearDownWithError() throws {
        database = nil
        if let tempDirectory {
            try? FileManager.default.removeItem(at: tempDirectory)
        }
        tempDirectory = nil
    }

    private func removeConfirmationSchema(from database: SpeakerDatabase) throws {
        let result = database.queue.sync {
            sqlite3_exec(database.db, """
            DROP TABLE IF EXISTS speaker_confirmation_moves;
            DROP TABLE IF EXISTS speaker_profile_confirmations;
            DROP TABLE IF EXISTS speaker_confirmation_migrations;
            """, nil, nil, nil)
        }
        XCTAssertEqual(result, SQLITE_OK)
        if result != SQLITE_OK {
            throw NSError(domain: "SpeakerConfirmationTests", code: Int(result))
        }
    }

    func testPassiveAppearancesNeverGraduateProfile() throws {
        let initial = database.addOrUpdateSpeaker(embedding: [1, 0], existingId: nil)
        database.setDisplayName(id: initial.id, name: "Alex", source: NameSource.userManual)
        for _ in 0..<20 {
            _ = database.addOrUpdateSpeaker(
                embedding: [1, 0],
                existingId: initial.id,
                blendAlpha: 0
            )
        }

        var profile = try XCTUnwrap(database.getSpeaker(id: initial.id))
        XCTAssertEqual(profile.callCount, 21)
        XCTAssertEqual(profile.confirmedMeetingCount, 0)
        XCTAssertFalse(SpeakerNamingPolicy.isAutoRecognizable(profile: profile, recentOutcomes: []))

        let meetings = (0..<5).map { _ in UUID() }
        try database.recordUserConfirmations([
            SpeakerUserConfirmation(profileId: profile.id, transcriptId: meetings[0], kind: .named),
            SpeakerUserConfirmation(profileId: profile.id, transcriptId: meetings[0], kind: .confirmed),
            SpeakerUserConfirmation(profileId: profile.id, transcriptId: meetings[1], kind: .confirmed),
            SpeakerUserConfirmation(profileId: profile.id, transcriptId: meetings[2], kind: .corrected),
            SpeakerUserConfirmation(profileId: profile.id, transcriptId: meetings[3], kind: .merged),
        ])

        profile = try XCTUnwrap(database.getSpeaker(id: profile.id))
        XCTAssertEqual(profile.confirmedMeetingCount, 4, "one meeting must count once even if two rows resolve to it")
        XCTAssertFalse(SpeakerNamingPolicy.isAutoRecognizable(profile: profile, recentOutcomes: []))

        try database.recordUserConfirmations([
            SpeakerUserConfirmation(profileId: profile.id, transcriptId: meetings[4], kind: .confirmed)
        ])
        profile = try XCTUnwrap(database.getSpeaker(id: profile.id))
        XCTAssertEqual(profile.confirmedMeetingCount, 5)
        XCTAssertTrue(SpeakerNamingPolicy.isAutoRecognizable(profile: profile, recentOutcomes: []))
    }

    func testMergeUsesSetUnionAndUnmergeRestoresBothConfirmationSets() throws {
        let source = database.addOrUpdateSpeaker(embedding: [1, 0], existingId: nil)
        let target = database.addOrUpdateSpeaker(embedding: [0, 1], existingId: nil)
        let sharedMeeting = UUID()
        try database.recordUserConfirmations([
            SpeakerUserConfirmation(profileId: source.id, transcriptId: UUID(), kind: .named),
            SpeakerUserConfirmation(profileId: source.id, transcriptId: sharedMeeting, kind: .confirmed),
            SpeakerUserConfirmation(profileId: target.id, transcriptId: sharedMeeting, kind: .confirmed),
            SpeakerUserConfirmation(profileId: target.id, transcriptId: UUID(), kind: .named),
        ])

        try database.mergeProfiles(sourceId: source.id, into: target.id)
        XCTAssertNil(database.getSpeaker(id: source.id))
        XCTAssertEqual(database.getSpeaker(id: target.id)?.confirmedMeetingCount, 3)

        let merge = try XCTUnwrap(database.undoableMerge(forTargetId: target.id))
        XCTAssertTrue(database.unmerge(mergeId: merge.id))
        XCTAssertEqual(database.getSpeaker(id: source.id)?.confirmedMeetingCount, 2)
        XCTAssertEqual(database.getSpeaker(id: target.id)?.confirmedMeetingCount, 2)
    }

    func testConservativeMigrationBackfillsOnlyPositiveExplicitOutcomes() throws {
        let path = tempDirectory.appendingPathComponent("migration.sqlite").path
        var migratingDatabase: SpeakerDatabase? = SpeakerDatabase(path: path)
        let profile = try XCTUnwrap(
            migratingDatabase?.addOrUpdateSpeaker(embedding: [1, 0], existingId: nil)
        )
        let first = UUID()
        let second = UUID()
        migratingDatabase?.recordMatchOutcomes([
            SpeakerMatchOutcome(profileId: profile.id, kind: .named, transcriptId: first),
            SpeakerMatchOutcome(profileId: profile.id, kind: .confirmed, transcriptId: first),
            SpeakerMatchOutcome(profileId: profile.id, kind: .merged, transcriptId: second),
            SpeakerMatchOutcome(profileId: profile.id, kind: .autoAccepted, transcriptId: UUID()),
            SpeakerMatchOutcome(profileId: profile.id, kind: .corrected, transcriptId: UUID()),
        ])
        try removeConfirmationSchema(from: try XCTUnwrap(migratingDatabase))
        migratingDatabase = nil

        let reopened = SpeakerDatabase(path: path)
        XCTAssertEqual(reopened.getSpeaker(id: profile.id)?.confirmedMeetingCount, 2)
    }

    func testLegacyMigrationReplaysActiveMergeAndUnmergeRestoresBothSets() throws {
        let path = tempDirectory.appendingPathComponent("merged-migration.sqlite").path
        var migratingDatabase: SpeakerDatabase? = SpeakerDatabase(path: path)
        let source = try XCTUnwrap(
            migratingDatabase?.addOrUpdateSpeaker(embedding: [1, 0], existingId: nil)
        )
        let target = try XCTUnwrap(
            migratingDatabase?.addOrUpdateSpeaker(embedding: [0, 1], existingId: nil)
        )
        let sharedMeeting = UUID()
        migratingDatabase?.recordMatchOutcomes([
            SpeakerMatchOutcome(profileId: source.id, kind: .named, transcriptId: UUID()),
            SpeakerMatchOutcome(profileId: source.id, kind: .confirmed, transcriptId: sharedMeeting),
            SpeakerMatchOutcome(profileId: target.id, kind: .confirmed, transcriptId: sharedMeeting),
            SpeakerMatchOutcome(profileId: target.id, kind: .merged, transcriptId: UUID()),
        ])
        try migratingDatabase?.mergeProfiles(sourceId: source.id, into: target.id)
        let mergeId = try XCTUnwrap(migratingDatabase?.undoableMerge(forTargetId: target.id)?.id)

        // Simulate an upgrade from a build that already had merge history and
        // match outcomes, but did not yet have the canonical confirmation ledger.
        try removeConfirmationSchema(from: try XCTUnwrap(migratingDatabase))
        migratingDatabase = nil

        let reopened = SpeakerDatabase(path: path)
        XCTAssertNil(reopened.getSpeaker(id: source.id))
        XCTAssertEqual(reopened.getSpeaker(id: target.id)?.confirmedMeetingCount, 3)

        XCTAssertTrue(reopened.unmerge(mergeId: mergeId))
        XCTAssertEqual(reopened.getSpeaker(id: source.id)?.confirmedMeetingCount, 2)
        XCTAssertEqual(reopened.getSpeaker(id: target.id)?.confirmedMeetingCount, 2)
    }

    func testCoordinatorAttributesCorrectionsToCorrectedToProfile() {
        let original = UUID()
        let correctedTarget = UUID()
        let mergedTarget = UUID()
        let transcriptId = UUID()
        let confirmations = TranscriptionTaskManager.plannedUserConfirmations(
            for: [
                SpeakerNameUpdate(
                    persistentSpeakerId: original,
                    diarizerSpeakerId: "0",
                    newName: "Correct Person",
                    action: .corrected,
                    resolvedPersistentSpeakerId: correctedTarget
                ),
                SpeakerNameUpdate(
                    persistentSpeakerId: UUID(),
                    diarizerSpeakerId: "1",
                    newName: "Merged Person",
                    action: .merged(targetProfileId: mergedTarget),
                    resolvedPersistentSpeakerId: mergedTarget
                ),
                SpeakerNameUpdate(
                    persistentSpeakerId: UUID(),
                    diarizerSpeakerId: "2",
                    newName: "You",
                    action: .collapsedToMe
                ),
            ],
            transcriptId: transcriptId
        )

        XCTAssertEqual(confirmations.count, 2)
        XCTAssertEqual(Set(confirmations.map(\.profileId)), Set([correctedTarget, mergedTarget]))
        XCTAssertTrue(confirmations.allSatisfy { $0.transcriptId == transcriptId })
    }
}
