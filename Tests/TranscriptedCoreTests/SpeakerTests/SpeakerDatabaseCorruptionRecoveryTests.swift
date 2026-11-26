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

    func testCorruptDatabaseMovesBothWalAndShmAsideAndStartsHealthy() throws {
        let dbURL = tempDirectory.appendingPathComponent("speakers.sqlite")
        let staleWal = Data(repeating: 0x5A, count: 4096)
        let staleShm = Data(repeating: 0x3C, count: 4096)
        try Data(repeating: 0xA5, count: 8192).write(to: dbURL)
        try staleWal.write(to: URL(fileURLWithPath: dbURL.path + "-wal"))
        try staleShm.write(to: URL(fileURLWithPath: dbURL.path + "-shm"))

        let database = SpeakerDatabase(path: dbURL.path)

        XCTAssertTrue(database.allSpeakers().isEmpty)
        let added = database.addOrUpdateSpeaker(embedding: [1, 0, 0, 0], existingId: nil)
        XCTAssertNotNil(database.getSpeaker(id: added.id), "the recreated database must accept writes")

        let names = try FileManager.default.contentsOfDirectory(atPath: tempDirectory.path)
        let backupWal = try XCTUnwrap(names.first { $0.hasPrefix("speakers_corrupt_") && $0.hasSuffix(".sqlite-wal") })
        let backupShm = try XCTUnwrap(names.first { $0.hasPrefix("speakers_corrupt_") && $0.hasSuffix(".sqlite-shm") })
        XCTAssertEqual(try Data(contentsOf: tempDirectory.appendingPathComponent(backupWal)), staleWal)
        let backupShmData = try Data(contentsOf: tempDirectory.appendingPathComponent(backupShm))
        XCTAssertFalse(backupShmData.isEmpty, "the corrupt -shm sidecar must be quarantined alongside the backup")
        XCTAssertNotEqual(try? Data(contentsOf: URL(fileURLWithPath: dbURL.path + "-wal")), staleWal)
        XCTAssertNotEqual(try? Data(contentsOf: URL(fileURLWithPath: dbURL.path + "-shm")), staleShm)
    }

    func testQuarantineCorruptArtifactsHandlesBackupPathCollision() throws {
        let dbURL = tempDirectory.appendingPathComponent("speakers.sqlite")
        let existingBackup = tempDirectory.appendingPathComponent("speakers_corrupt_existing.sqlite")
        let mainBytes = Data(repeating: 0x11, count: 1024)
        let walBytes = Data(repeating: 0x22, count: 1024)
        let shmBytes = Data(repeating: 0x33, count: 1024)
        try Data("existing".utf8).write(to: existingBackup)
        try mainBytes.write(to: dbURL)
        try walBytes.write(to: URL(fileURLWithPath: dbURL.path + "-wal"))
        try shmBytes.write(to: URL(fileURLWithPath: dbURL.path + "-shm"))

        let moved = SQLiteHandle.quarantineCorruptArtifacts(at: dbURL, to: existingBackup)

        XCTAssertTrue(moved)
        XCTAssertFalse(FileManager.default.fileExists(atPath: dbURL.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: dbURL.path + "-wal"))
        XCTAssertFalse(FileManager.default.fileExists(atPath: dbURL.path + "-shm"))
        XCTAssertEqual(try Data(contentsOf: existingBackup), Data("existing".utf8), "pre-existing backup must remain intact")
        let names = try FileManager.default.contentsOfDirectory(atPath: tempDirectory.path)
        XCTAssertTrue(names.contains { $0.hasPrefix("speakers_corrupt_existing_") && $0.hasSuffix(".sqlite") })
        XCTAssertTrue(names.contains { $0.hasPrefix("speakers_corrupt_existing_") && $0.hasSuffix(".sqlite-wal") })
        XCTAssertTrue(names.contains { $0.hasPrefix("speakers_corrupt_existing_") && $0.hasSuffix(".sqlite-shm") })
    }

    func testQuarantineCorruptArtifactsLeavesSidecarsUntouchedWhenMainMoveFails() throws {
        let dbURL = tempDirectory.appendingPathComponent("speakers.sqlite")
        let missingDirBackup = tempDirectory
            .appendingPathComponent("nonexistent_backup_dir", isDirectory: true)
            .appendingPathComponent("speakers_corrupt.sqlite")
        let mainBytes = Data(repeating: 0x11, count: 1024)
        let walBytes = Data(repeating: 0x22, count: 1024)
        let shmBytes = Data(repeating: 0x33, count: 1024)
        let walURL = URL(fileURLWithPath: dbURL.path + "-wal")
        let shmURL = URL(fileURLWithPath: dbURL.path + "-shm")
        try mainBytes.write(to: dbURL)
        try walBytes.write(to: walURL)
        try shmBytes.write(to: shmURL)

        var failedSuffixes: [String] = []
        let moved = SQLiteHandle.quarantineCorruptArtifacts(
            at: dbURL,
            to: missingDirBackup,
            onMoveFailure: { suffix, _ in
                failedSuffixes.append(suffix)
            }
        )

        XCTAssertFalse(moved, "quarantineCorruptArtifacts must return false when moving main .sqlite fails")
        XCTAssertEqual(failedSuffixes, [""], "must stop immediately after main .sqlite move failure without touching sidecars")
        XCTAssertEqual(try Data(contentsOf: dbURL), mainBytes, "main .sqlite must stay untouched")
        XCTAssertEqual(try Data(contentsOf: walURL), walBytes, "-wal sidecar must not be moved or deleted when main move fails")
        XCTAssertEqual(try Data(contentsOf: shmURL), shmBytes, "-shm sidecar must not be moved or deleted when main move fails")
    }
}
