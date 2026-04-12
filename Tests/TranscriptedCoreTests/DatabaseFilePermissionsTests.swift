import XCTest
@testable import TranscriptedCore

@available(macOS 14.0, *)
final class DatabaseFilePermissionsTests: XCTestCase {

    func testStatsDatabaseRestrictsSQLiteArtifactsToOwnerOnly() {
        let databaseURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("DatabaseFilePermissionsStats-\(UUID().uuidString).sqlite")
        defer { cleanupSQLiteArtifacts(at: databaseURL) }

        let database = StatsDatabase(path: databaseURL.path)
        database.recordSession(
            RecordingMetadata(
                id: "permission-check",
                date: Date(),
                durationSeconds: 90
            )
        )
        database.queue.sync {}

        assertSQLiteArtifactsAreOwnerOnly(at: databaseURL)
    }

    func testSpeakerDatabaseRestrictsSQLiteArtifactsToOwnerOnly() {
        let databaseURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("DatabaseFilePermissionsSpeakers-\(UUID().uuidString).sqlite")
        defer { cleanupSQLiteArtifacts(at: databaseURL) }

        let database = SpeakerDatabase(path: databaseURL.path)
        _ = database.addOrUpdateSpeaker(embedding: Array(repeating: 0.25, count: 256))
        database.queue.sync {}

        assertSQLiteArtifactsAreOwnerOnly(at: databaseURL)
    }

    private func assertSQLiteArtifactsAreOwnerOnly(at databaseURL: URL, file: StaticString = #filePath, line: UInt = #line) {
        for suffix in ["", "-wal", "-shm"] {
            let artifactURL = URL(fileURLWithPath: databaseURL.path + suffix)
            XCTAssertTrue(
                FileManager.default.fileExists(atPath: artifactURL.path),
                "Expected SQLite artifact to exist: \(artifactURL.lastPathComponent)",
                file: file,
                line: line
            )

            let attributes = try? FileManager.default.attributesOfItem(atPath: artifactURL.path)
            let permissions = attributes?[.posixPermissions] as? NSNumber
            XCTAssertEqual(
                permissions,
                NSNumber(value: 0o600),
                "SQLite artifact should be restricted to owner-only permissions: \(artifactURL.lastPathComponent)",
                file: file,
                line: line
            )
        }
    }

    private func cleanupSQLiteArtifacts(at databaseURL: URL) {
        for suffix in ["", "-wal", "-shm"] {
            try? FileManager.default.removeItem(at: URL(fileURLWithPath: databaseURL.path + suffix))
        }
    }
}
