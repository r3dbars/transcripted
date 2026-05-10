import XCTest
import SQLite3
@testable import TranscriptedCore

@available(macOS 14.0, *)
final class SpeakerProfileMergerTests: XCTestCase {

    private var tempDirectory: URL!
    private var database: SpeakerDatabase!

    override func setUpWithError() throws {
        tempDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("SpeakerProfileMergerTests-\(UUID().uuidString)")
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

    func testSpeakerDatabaseCreatesLookupIndexes() {
        let indexes = speakerIndexNames()

        XCTAssertTrue(indexes.contains("idx_speakers_display_name"))
        XCTAssertTrue(indexes.contains("idx_speakers_last_seen"))
    }

    func testFindProfilesByNamePreservesVariantMatchesAndSortsByCallCount() {
        let nate = database.addOrUpdateSpeaker(
            embedding: [Float](repeating: 0.25, count: 256),
            existingId: nil
        )
        database.setDisplayName(id: nate.id, name: "Nate", source: NameSource.userManual)

        let nathan = database.addOrUpdateSpeaker(
            embedding: [Float](repeating: 0.35, count: 256),
            existingId: nil
        )
        database.setDisplayName(id: nathan.id, name: "Nathan", source: NameSource.userManual)
        _ = database.addOrUpdateSpeaker(
            embedding: [Float](repeating: 0.36, count: 256),
            existingId: nathan.id
        )

        let unmatched = database.addOrUpdateSpeaker(
            embedding: [Float](repeating: 0.45, count: 256),
            existingId: nil
        )
        database.setDisplayName(id: unmatched.id, name: "Sarah", source: NameSource.userManual)

        let matches = database.findProfilesByName("Nathaniel")

        XCTAssertEqual(matches.map(\.id), [nathan.id, nate.id])
    }

    func testMergeProfilesByNamePreservesCaseInsensitiveExactMergeOnly() {
        let first = database.addOrUpdateSpeaker(
            embedding: [Float](repeating: 0.20, count: 256),
            existingId: nil
        )
        let second = database.addOrUpdateSpeaker(
            embedding: [Float](repeating: 0.22, count: 256),
            existingId: nil
        )
        let variant = database.addOrUpdateSpeaker(
            embedding: [Float](repeating: 0.24, count: 256),
            existingId: nil
        )

        database.setDisplayName(id: first.id, name: "Alex", source: NameSource.userManual)
        database.setDisplayName(id: second.id, name: " alex ", source: NameSource.userManual)
        database.setDisplayName(id: variant.id, name: "Alexander", source: NameSource.userManual)

        database.mergeProfilesByName()

        XCTAssertEqual(database.allSpeakers().count, 2)
        XCTAssertNotNil(database.getSpeaker(id: variant.id))
    }

    func testMergeDuplicatesSkipsDisputedProfiles() {
        let first = database.addOrUpdateSpeaker(
            embedding: [Float](repeating: 0.25, count: 256),
            existingId: nil
        )
        let second = database.addOrUpdateSpeaker(
            embedding: [Float](repeating: 0.25, count: 256),
            existingId: nil
        )

        database.incrementDisputeCount(id: first.id)
        database.mergeDuplicates(threshold: 0.6)

        XCTAssertNotNil(database.getSpeaker(id: first.id))
        XCTAssertNotNil(database.getSpeaker(id: second.id))
    }

    func testMergeDuplicatesSkipsConflictingNamedProfiles() {
        let first = database.addOrUpdateSpeaker(
            embedding: [Float](repeating: 0.4, count: 256),
            existingId: nil
        )
        let second = database.addOrUpdateSpeaker(
            embedding: [Float](repeating: 0.4, count: 256),
            existingId: nil
        )

        database.setDisplayName(id: first.id, name: "Matt Vlasach", source: NameSource.userManual)
        database.setDisplayName(id: second.id, name: "Sarah Graham", source: NameSource.userManual)
        database.mergeDuplicates(threshold: 0.6)

        XCTAssertNotNil(database.getSpeaker(id: first.id))
        XCTAssertNotNil(database.getSpeaker(id: second.id))
    }

    func testPruneWeakProfilesKeepsDeferredProfilesWithReviewSamples() throws {
        let profileId = UUID()
        _ = database.addOrUpdateSpeaker(
            embedding: [Float](repeating: 0.25, count: 256),
            existingId: profileId
        )
        let staleProfile = SpeakerProfile(
            id: profileId,
            displayName: nil,
            nameSource: nil,
            embedding: [Float](repeating: 0.25, count: 256),
            firstSeen: Date().addingTimeInterval(-7200),
            lastSeen: Date().addingTimeInterval(-7200),
            callCount: 1,
            confidence: 0.5,
            disputeCount: 0
        )
        database.restoreProfile(staleProfile)

        let clipsDirectory = tempDirectory.appendingPathComponent("speaker_clips", isDirectory: true)
        try FileManager.default.createDirectory(at: clipsDirectory, withIntermediateDirectories: true)
        try Data("clip".utf8).write(to: clipsDirectory.appendingPathComponent("\(profileId.uuidString).wav"))

        database.pruneWeakProfiles()

        XCTAssertNotNil(
            database.getSpeaker(id: profileId),
            "deferred unnamed profiles with review samples should survive pruning"
        )
    }

    private func speakerIndexNames() -> Set<String> {
        database.queue.sync {
            var names: Set<String> = []
            var statement: OpaquePointer?
            if sqlite3_prepare_v2(database.db, "PRAGMA index_list(speakers);", -1, &statement, nil) == SQLITE_OK {
                while sqlite3_step(statement) == SQLITE_ROW {
                    if let namePtr = sqlite3_column_text(statement, 1) {
                        names.insert(String(cString: namePtr))
                    }
                }
            }
            sqlite3_finalize(statement)
            return names
        }
    }
}
