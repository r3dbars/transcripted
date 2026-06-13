import XCTest
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

    func testMergeDuplicatesPreservesProtectedPendingProfiles() {
        let first = database.addOrUpdateSpeaker(
            embedding: [Float](repeating: 0.25, count: 256),
            existingId: nil
        )
        let second = database.addOrUpdateSpeaker(
            embedding: [Float](repeating: 0.25, count: 256),
            existingId: nil
        )

        database.mergeDuplicates(threshold: 0.6, protecting: [first.id])

        XCTAssertNotNil(
            database.getSpeaker(id: first.id),
            "Profiles referenced by pending speaker review rows must not be absorbed before review completes."
        )
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
}
