import Foundation
import XCTest
@testable import TranscriptedCore

/// Conservative Stats refusal, not a proof of stale-WAL replay or recovery of
/// user data. Every database and byte belongs to this one synthetic fixture.
@available(macOS 14.0, *)
final class StatsDatabaseCorruptionSafetyTests: XCTestCase {
    private var parent: URL!
    private var root: URL!

    override func setUpWithError() throws {
        guard ProcessInfo.processInfo.environment["TRANSCRIPTED_DISABLE_FILE_LOGGER"] == "1" else {
            XCTFail("Stats safety fixtures require the file logger to be disabled")
            throw FixtureFailure.loggerEnabled
        }
        parent = FileManager.default.temporaryDirectory.resolvingSymlinksInPath().standardizedFileURL
        root = parent.appendingPathComponent("StatsDatabaseCorruptionSafetyTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
    }

    override func tearDownWithError() throws {
        guard let root, let parent else { return }
        defer { self.root = nil; self.parent = nil }
        let prefix = "StatsDatabaseCorruptionSafetyTests-"
        let canonical = root.resolvingSymlinksInPath().standardizedFileURL
        guard root.lastPathComponent.hasPrefix(prefix),
              UUID(uuidString: String(root.lastPathComponent.dropFirst(prefix.count))) != nil,
              canonical.path == root.path,
              canonical.deletingLastPathComponent().path == parent.path else {
            XCTFail("Refusing cleanup outside the exact owned Stats fixture")
            throw FixtureFailure.unsafeCleanup
        }
        if FileManager.default.fileExists(atPath: root.path) {
            do { try FileManager.default.removeItem(at: root) }
            catch {
                XCTFail("Could not remove the owned Stats fixture")
                throw FixtureFailure.cleanupFailed
            }
        }
    }

    func testCorruptOwnedStoreIsUnavailableAndNotReplaced() throws {
        let target = try makeCorruptClosedCopy()
        let corruptBytes = try Data(contentsOf: target)
        try withClosedDatabase(at: target) { database in
            XCTAssertFalse(database.isDatabaseOpen, "a corrupt existing store must not silently become an empty healthy store")
            XCTAssertNil(database.db, "the refused store must have no active query/write handle")
            XCTAssertTrue(database.getAllRecordings().isEmpty)
        }
        XCTAssertEqual(try Data(contentsOf: target), corruptBytes, "preserve the corrupt main file for repair instead of replacing it")
        try assertNoRecoveryBackup()
    }

    func testUnavailableOwnedStoreDoesNotResumeIndexing() throws {
        let target = try makeCorruptClosedCopy()
        let corruptBytes = try Data(contentsOf: target)
        try withClosedDatabase(at: target) { database in
            database.recordSession(metadata(id: "refused-recording"))
            database.queue.sync {}
            XCTAssertFalse(database.isDatabaseOpen, "recordSession must not reopen an unavailable store")
            XCTAssertNil(database.db)
            XCTAssertTrue(database.getAllRecordings().isEmpty, "the fire-and-forget writer must refuse indexing")
        }
        XCTAssertEqual(try Data(contentsOf: target), corruptBytes, "a metadata write must not replace the refused database")
        try assertNoRecoveryBackup()
    }

    func testHealthyOwnedStoreKeepsExistingRows() throws {
        let seed = try makeClosedSeed()
        let target = root.appendingPathComponent("healthy.sqlite")
        try FileManager.default.copyItem(at: seed, to: target)
        try withClosedDatabase(at: target) { database in
            XCTAssertTrue(database.isDatabaseOpen)
            XCTAssertNotNil(database.db)
            XCTAssertEqual(database.getAllRecordings().map(\.id), ["seed-recording"], "healthy existing data remains available")
            database.recordSession(metadata(id: "second-recording"))
            database.queue.sync {}
            XCTAssertEqual(Set(database.getAllRecordings().map(\.id)), Set(["seed-recording", "second-recording"]))
        }
        try assertNoRecoveryBackup()
    }

    func testMissingOwnedStoreCreatesUsableFreshDatabase() throws {
        let target = root.appendingPathComponent("new.sqlite")
        XCTAssertFalse(FileManager.default.fileExists(atPath: target.path))
        try withClosedDatabase(at: target) { database in
            XCTAssertTrue(database.isDatabaseOpen, "a legitimate first store still initializes")
            XCTAssertNotNil(database.db)
            database.recordSession(metadata(id: "first-recording"))
            database.queue.sync {}
            XCTAssertEqual(database.getAllRecordings().map(\.id), ["first-recording"])
        }
        XCTAssertTrue(FileManager.default.fileExists(atPath: target.path))
        try assertNoRecoveryBackup()
    }

    private func metadata(id: String) -> RecordingMetadata {
        RecordingMetadata(id: id, date: Date(timeIntervalSince1970: 1_700_000_000), durationSeconds: 60)
    }

    /// Keep the actual seed's handle closed before any file copy or corruption.
    private func makeClosedSeed() throws -> URL {
        let seed = root.appendingPathComponent("seed.sqlite")
        try withClosedDatabase(at: seed) { database in
            XCTAssertTrue(database.isDatabaseOpen)
            database.recordSession(metadata(id: "seed-recording"))
            database.queue.sync {}
            XCTAssertEqual(database.getAllRecordings().map(\.id), ["seed-recording"])
        }
        return seed
    }

    private func makeCorruptClosedCopy() throws -> URL {
        let seed = try makeClosedSeed()
        let target = root.appendingPathComponent("corrupt.sqlite")
        try FileManager.default.copyItem(at: seed, to: target)
        var bytes = try Data(contentsOf: target)
        guard bytes.count >= 16 else {
            XCTFail("The synthetic SQLite seed did not produce a complete header")
            throw FixtureFailure.shortSeed
        }
        // No connection owns this target yet. Damage only its copied header,
        // not an open database or any file outside this fixture.
        bytes.replaceSubrange(0..<16, with: Data(repeating: 0xA5, count: 16))
        try bytes.write(to: target, options: .atomic)
        return target
    }

    private func withClosedDatabase(at url: URL, body: (StatsDatabase) throws -> Void) throws {
        var database: StatsDatabase? = StatsDatabase(path: url.path)
        weak var observed = database
        do {
            try body(try XCTUnwrap(database))
            database?.queue.sync {}
        } catch {
            database?.queue.sync {}
            database = nil
            XCTAssertNil(observed, "the owned database must close before cleanup")
            throw error
        }
        database = nil
        guard observed == nil else {
            XCTFail("The owned database must close before copy, mutation or cleanup")
            throw FixtureFailure.databaseRetained
        }
    }

    private func assertNoRecoveryBackup() throws {
        let names = try FileManager.default.contentsOfDirectory(atPath: root.path)
        XCTAssertFalse(names.contains { $0.hasPrefix("stats_corrupt_") }, "refusal must not move a potentially shared database aside")
    }

    private enum FixtureFailure: Error {
        case loggerEnabled, unsafeCleanup, cleanupFailed, shortSeed, databaseRetained
    }
}
