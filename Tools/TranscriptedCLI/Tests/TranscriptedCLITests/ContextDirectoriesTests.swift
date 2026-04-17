import XCTest
@testable import transcripted_cli

final class ContextDirectoriesTests: XCTestCase {
    func testResolveFallsBackToLegacyDraftWhenOnlyLegacyDictationsExist() throws {
        let tempHome = makeTempDir()
        defer { removeTempDir(tempHome) }

        let legacyDraftDictations = tempHome
            .appendingPathComponent("Library", isDirectory: true)
            .appendingPathComponent("Application Support", isDirectory: true)
            .appendingPathComponent("Draft", isDirectory: true)
            .appendingPathComponent("dictations", isDirectory: true)
            .appendingPathComponent("transcripts", isDirectory: true)
        try FileManager.default.createDirectory(at: legacyDraftDictations, withIntermediateDirectories: true)

        let directories = CLIContextDirectories.resolve(
            dataDir: nil,
            meetingsDir: nil,
            dictationsDir: nil,
            environment: [:],
            fileManager: .default,
            homeDirectory: tempHome
        )

        XCTAssertEqual(
            directories.meetingsDir.path,
            tempHome
                .appendingPathComponent("Library", isDirectory: true)
                .appendingPathComponent("Application Support", isDirectory: true)
                .appendingPathComponent("Draft", isDirectory: true)
                .appendingPathComponent("meetings", isDirectory: true)
                .appendingPathComponent("transcripts", isDirectory: true)
                .path
        )
        XCTAssertEqual(directories.dictationsDir.path, legacyDraftDictations.path)
    }

    func testResolvePrefersCurrentTranscriptedLayoutWhenOnlyCurrentDictationsExist() throws {
        let tempHome = makeTempDir()
        defer { removeTempDir(tempHome) }

        let transcriptedDictations = tempHome
            .appendingPathComponent("Library", isDirectory: true)
            .appendingPathComponent("Application Support", isDirectory: true)
            .appendingPathComponent("Transcripted", isDirectory: true)
            .appendingPathComponent("captures", isDirectory: true)
            .appendingPathComponent("dictations", isDirectory: true)
        try FileManager.default.createDirectory(at: transcriptedDictations, withIntermediateDirectories: true)

        let legacyDraftMeetings = tempHome
            .appendingPathComponent("Library", isDirectory: true)
            .appendingPathComponent("Application Support", isDirectory: true)
            .appendingPathComponent("Draft", isDirectory: true)
            .appendingPathComponent("meetings", isDirectory: true)
            .appendingPathComponent("transcripts", isDirectory: true)
        try FileManager.default.createDirectory(at: legacyDraftMeetings, withIntermediateDirectories: true)

        let directories = CLIContextDirectories.resolve(
            dataDir: nil,
            meetingsDir: nil,
            dictationsDir: nil,
            environment: [:],
            fileManager: .default,
            homeDirectory: tempHome
        )

        XCTAssertEqual(
            directories.meetingsDir.path,
            tempHome
                .appendingPathComponent("Library", isDirectory: true)
                .appendingPathComponent("Application Support", isDirectory: true)
                .appendingPathComponent("Transcripted", isDirectory: true)
                .appendingPathComponent("captures", isDirectory: true)
                .appendingPathComponent("meetings", isDirectory: true)
                .path
        )
        XCTAssertEqual(directories.dictationsDir.path, transcriptedDictations.path)
    }
    private func makeTempDir() -> URL {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try! FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    private func removeTempDir(_ dir: URL) {
        try? FileManager.default.removeItem(at: dir)
    }
}
