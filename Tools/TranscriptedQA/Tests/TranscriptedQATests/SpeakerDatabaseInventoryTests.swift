import SQLite3
import XCTest
@testable import transcripted_qa

final class SpeakerDatabaseInventoryTests: XCTestCase {
    func testEachShippingSpeakerDatabaseUsesItsOwnEmbeddingSizeAndTarget() throws {
        for (filename, bytes) in [("speakers.sqlite", 1024), ("speakers_eres2net.sqlite", 768), ("speakers_redimnet2-b4.sqlite", 768)] {
            let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
            defer { try? FileManager.default.removeItem(at: root) }
            let path = try makeDatabase(in: root, filename: filename, embeddingBytes: bytes)
            let results = SpeakerDBValidator(dbPath: path.path).validate()
            XCTAssertEqual(results.first { $0.check == "database/speakers-embedding-size" }?.status, .pass, filename)
            XCTAssertTrue(results.allSatisfy { $0.target == filename }, "identify the database actually inspected")
            XCTAssertFalse(results.contains { $0.status == .fail }, filename)
            let discovered = SpeakerDBValidator.validateAll(in: root)
            XCTAssertTrue(discovered.allSatisfy { $0.target == filename }, "validate-all must inspect the actual per-model database")
            XCTAssertEqual(discovered.first { $0.check == "database/speakers-embedding-size" }?.status, .pass)
        }
    }

    func testInventoryFindsTheDefaultDatabaseWithoutIncludingSidecarsOrOtherStores() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        _ = try makeDatabase(in: root, filename: "speakers_redimnet2-b4.sqlite", embeddingBytes: 768)
        for filename in ["stats.sqlite", "speakers.sqlite-wal", "speakers.sqlite-shm", "unrelated.sqlite"] {
            try Data().write(to: root.appendingPathComponent(filename))
        }
        let artifacts = try SpeakerDatabaseArtifact.existing(in: root)
        XCTAssertEqual(artifacts.map(\.url.lastPathComponent), ["speakers_redimnet2-b4.sqlite"])
        XCTAssertEqual(artifacts.map(\.displayName), ["ReDimNet2"])
        XCTAssertTrue(try SpeakerDatabaseArtifact.existing(in: root.appendingPathComponent("absent")).isEmpty)
    }

    func testWrongDimensionsStillFailForEveryShippingDatabase() throws {
        for (filename, bytes) in [("speakers.sqlite", 768), ("speakers_eres2net.sqlite", 1024), ("speakers_redimnet2-b4.sqlite", 1024)] {
            let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
            defer { try? FileManager.default.removeItem(at: root) }
            let path = try makeDatabase(in: root, filename: filename, embeddingBytes: bytes)
            let results = SpeakerDBValidator(dbPath: path.path).validate()
            XCTAssertEqual(results.first { $0.check == "database/speakers-embedding-size" }?.status, .fail, filename)
        }
    }

    private func makeDatabase(in root: URL, filename: String, embeddingBytes: Int) throws -> URL {
        try TestDataGenerator(outputDir: root).generateSpeakerDB(speakerCount: 1)
        let legacy = root.appendingPathComponent("speakers.sqlite")
        let result = root.appendingPathComponent(filename)
        if legacy != result { try FileManager.default.moveItem(at: legacy, to: result) }
        var database: OpaquePointer?
        XCTAssertEqual(sqlite3_open(result.path, &database), SQLITE_OK)
        let opened = try XCTUnwrap(database)
        defer { sqlite3_close(opened) }
        XCTAssertEqual(sqlite3_exec(opened, "UPDATE speakers SET embedding = zeroblob(\(embeddingBytes))", nil, nil, nil), SQLITE_OK)
        return result
    }
}
