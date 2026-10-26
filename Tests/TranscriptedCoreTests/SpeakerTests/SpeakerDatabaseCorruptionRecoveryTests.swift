import XCTest
@testable import TranscriptedCore

/// A corrupt speaker database is moved aside together with its -wal and -shm,
/// so the fresh database never replays the old WAL and the backup keeps it.
@available(macOS 14.0, *)
final class SpeakerDatabaseCorruptionRecoveryTests: XCTestCase {
    private var tempDirectory: URL!

    override func setUpWithError() throws {
        tempDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("SpeakerDatabaseCorruptionRecoveryTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tempDirectory, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        if let tempDirectory {
            try? FileManager.default.removeItem(at: tempDirectory)
        }
        tempDirectory = nil
    }

    func testCorruptDatabaseMovesItsWalAsideAndStartsEmptyAndHealthy() throws {
        let dbURL = tempDirectory.appendingPathComponent("speakers.sqlite")
        let staleWal = Data(repeating: 0x5A, count: 4096)
        try Data(repeating: 0xA5, count: 8192).write(to: dbURL)
        try staleWal.write(to: URL(fileURLWithPath: dbURL.path + "-wal"))

        let database = SpeakerDatabase(path: dbURL.path)

        XCTAssertTrue(database.allSpeakers().isEmpty)
        let added = database.addOrUpdateSpeaker(embedding: [1, 0], existingId: nil)
        XCTAssertNotNil(database.getSpeaker(id: added.id), "the fresh database accepts writes")

        let names = try FileManager.default.contentsOfDirectory(atPath: tempDirectory.path)
        let backupWal = try XCTUnwrap(names.first { $0.hasPrefix("speakers_corrupt_") && $0.hasSuffix(".sqlite-wal") })
        XCTAssertEqual(try Data(contentsOf: tempDirectory.appendingPathComponent(backupWal)), staleWal)
        XCTAssertTrue(names.contains { $0.hasPrefix("speakers_corrupt_") && $0.hasSuffix(".sqlite") })
        let currentWal = try? Data(contentsOf: URL(fileURLWithPath: dbURL.path + "-wal"))
        XCTAssertNotEqual(currentWal, staleWal, "the stale WAL must not stay next to the fresh database")
    }
}
