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
}
