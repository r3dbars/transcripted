import Foundation
import SQLite3
import XCTest
@testable import transcripted_cli

final class SpeakerDatabaseSnapshotTests: XCTestCase {
    func testSnapshotIncludesCommittedWALRowsWithoutChangingSource() throws {
        let folder = try temporaryFolder()
        defer { try? FileManager.default.removeItem(at: folder) }
        let source = folder.appendingPathComponent("äänet speakers.sqlite")
        let destination = folder.appendingPathComponent("private ää.sqlite")
        let database = try openDatabase(source)
        defer { sqlite3_close(database) }
        try execute(database, "PRAGMA journal_mode=WAL; PRAGMA wal_autocheckpoint=0; CREATE TABLE speakers (name TEXT); INSERT INTO speakers VALUES ('Fixture Alpha');")
        let original = try Data(contentsOf: source)
        let walURL = URL(fileURLWithPath: source.path + "-wal")
        let originalWAL = try Data(contentsOf: walURL)
        XCTAssertGreaterThan(originalWAL.count, 32)

        try SpeakerDatabaseSnapshot.create(sourceURL: source, destinationURL: destination)

        XCTAssertEqual(try Data(contentsOf: source), original)
        XCTAssertEqual(try Data(contentsOf: walURL), originalWAL)
        let snapshot = try openDatabase(destination)
        defer { sqlite3_close(snapshot) }
        XCTAssertEqual(try scalar(snapshot, "SELECT name FROM speakers"), "Fixture Alpha")
        try execute(snapshot, "UPDATE speakers SET name='Private Change';")
        XCTAssertEqual(try scalar(database, "SELECT name FROM speakers"), "Fixture Alpha")
        XCTAssertEqual(try scalar(snapshot, "SELECT name FROM speakers"), "Private Change")
        try execute(database, "INSERT INTO speakers VALUES ('Later App Change');")
        XCTAssertEqual(try scalar(snapshot, "SELECT count(*) FROM speakers"), "1")
        XCTAssertEqual(try scalar(database, "SELECT count(*) FROM speakers"), "2")
        let attributes = try FileManager.default.attributesOfItem(atPath: destination.path)
        XCTAssertEqual((attributes[.posixPermissions] as? NSNumber)?.intValue, 0o600)
    }

    func testMissingSourceDoesNotCreateDatabaseOrDestination() throws {
        let folder = try temporaryFolder()
        defer { try? FileManager.default.removeItem(at: folder) }
        let source = folder.appendingPathComponent("missing.sqlite")
        let destination = folder.appendingPathComponent("private.sqlite")
        XCTAssertThrowsError(try SpeakerDatabaseSnapshot.create(sourceURL: source, destinationURL: destination))
        XCTAssertFalse(FileManager.default.fileExists(atPath: source.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: destination.path))
    }

    func testCorruptSourceIsNeverRepairedAndFailedSnapshotIsRemoved() throws {
        let folder = try temporaryFolder()
        defer { try? FileManager.default.removeItem(at: folder) }
        let source = folder.appendingPathComponent("corrupt.sqlite")
        let destination = folder.appendingPathComponent("private.sqlite")
        let bytes = Data("This is not a database".utf8)
        try bytes.write(to: source)
        XCTAssertThrowsError(try SpeakerDatabaseSnapshot.create(sourceURL: source, destinationURL: destination)) { error in
            XCTAssertEqual(error as? SpeakerDatabaseSnapshot.SnapshotError, .invalidDatabase)
        }
        XCTAssertEqual(try Data(contentsOf: source), bytes)
        XCTAssertFalse(FileManager.default.fileExists(atPath: destination.path))
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: folder.path), ["corrupt.sqlite"])
    }

    func testExistingDestinationIsNeverOverwritten() throws {
        let folder = try temporaryFolder()
        defer { try? FileManager.default.removeItem(at: folder) }
        let source = folder.appendingPathComponent("source.sqlite")
        let destination = folder.appendingPathComponent("existing.sqlite")
        let database = try openDatabase(source)
        defer { sqlite3_close(database) }
        try execute(database, "CREATE TABLE speakers (name TEXT)")
        let bytes = Data("Keep this existing file".utf8)
        try bytes.write(to: destination)
        XCTAssertThrowsError(try SpeakerDatabaseSnapshot.create(sourceURL: source, destinationURL: destination)) { error in
            XCTAssertEqual(error as? SpeakerDatabaseSnapshot.SnapshotError, .destinationExists)
        }
        XCTAssertEqual(try Data(contentsOf: destination), bytes)
    }

    func testDirectoryEmptyFileAndSymbolicLinkSourcesAreRejected() throws {
        let folder = try temporaryFolder()
        defer { try? FileManager.default.removeItem(at: folder) }
        let empty = folder.appendingPathComponent("empty.sqlite")
        try Data().write(to: empty)
        let link = folder.appendingPathComponent("source-link.sqlite")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: empty)
        for source in [folder, empty, link] {
            XCTAssertThrowsError(try SpeakerDatabaseSnapshot.create(
                sourceURL: source, destinationURL: folder.appendingPathComponent(UUID().uuidString)
            )) { error in
                XCTAssertEqual(error as? SpeakerDatabaseSnapshot.SnapshotError, .invalidSource)
            }
        }
    }

    func testSymlinkDestinationIsRejectedWithoutChangingItsTarget() throws {
        let folder = try temporaryFolder()
        defer { try? FileManager.default.removeItem(at: folder) }
        let source = folder.appendingPathComponent("source.sqlite")
        let database = try openDatabase(source)
        defer { sqlite3_close(database) }
        try execute(database, "CREATE TABLE speakers (name TEXT)")
        let target = folder.appendingPathComponent("untouched.txt")
        let bytes = Data("Unrelated content".utf8)
        try bytes.write(to: target)
        let link = folder.appendingPathComponent("snapshot.sqlite")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: target)
        XCTAssertThrowsError(try SpeakerDatabaseSnapshot.create(sourceURL: source, destinationURL: link)) { error in
            XCTAssertEqual(error as? SpeakerDatabaseSnapshot.SnapshotError, .destinationExists)
        }
        XCTAssertEqual(try Data(contentsOf: target), bytes)
    }

    func testExclusiveLockFailsWithinBoundAndPreservesSource() throws {
        let folder = try temporaryFolder()
        defer { try? FileManager.default.removeItem(at: folder) }
        let source = folder.appendingPathComponent("source.sqlite")
        let destination = folder.appendingPathComponent("private.sqlite")
        let database = try openDatabase(source)
        defer { sqlite3_close(database) }
        try execute(database, "CREATE TABLE speakers (name TEXT); INSERT INTO speakers VALUES ('Fixture Beta'); BEGIN EXCLUSIVE;")
        defer { sqlite3_exec(database, "ROLLBACK", nil, nil, nil) }
        let original = try Data(contentsOf: source)
        let start = ProcessInfo.processInfo.systemUptime
        XCTAssertThrowsError(try SpeakerDatabaseSnapshot.create(sourceURL: source, destinationURL: destination, busyTimeout: 0.05)) { error in
            XCTAssertEqual(error as? SpeakerDatabaseSnapshot.SnapshotError, .busy)
        }
        XCTAssertLessThan(ProcessInfo.processInfo.systemUptime - start, 1)
        XCTAssertEqual(try Data(contentsOf: source), original)
        XCTAssertFalse(FileManager.default.fileExists(atPath: destination.path))
    }

    private func temporaryFolder() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("SpeakerSnapshotTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        return url
    }

    private func openDatabase(_ url: URL) throws -> OpaquePointer {
        var database: OpaquePointer?
        let code = sqlite3_open(url.path, &database)
        guard code == SQLITE_OK, let database else {
            if let database { sqlite3_close(database) }
            throw NSError(domain: "SnapshotFixture", code: Int(code))
        }
        return database
    }

    private func execute(_ database: OpaquePointer, _ sql: String) throws {
        let code = sqlite3_exec(database, sql, nil, nil, nil)
        guard code == SQLITE_OK else { throw NSError(domain: "SnapshotFixture", code: Int(code)) }
    }

    private func scalar(_ database: OpaquePointer, _ sql: String) throws -> String {
        var statement: OpaquePointer?
        let code = sqlite3_prepare_v2(database, sql, -1, &statement, nil)
        defer { sqlite3_finalize(statement) }
        guard code == SQLITE_OK, sqlite3_step(statement) == SQLITE_ROW,
              let value = sqlite3_column_text(statement, 0) else {
            throw NSError(domain: "SnapshotFixture", code: Int(sqlite3_errcode(database)))
        }
        return String(cString: value)
    }
}
