import XCTest
@testable import transcripted_cli

final class ContextDirectoriesTests: XCTestCase {
    func testResolveIncludesLegacyDraftMarkdownAfterCurrentDefaults() throws {
        let tempHome = makeTempDir()
        defer { removeTempDir(tempHome) }

        let transcriptedRoot = tempHome
            .appendingPathComponent("Library", isDirectory: true)
            .appendingPathComponent("Application Support", isDirectory: true)
            .appendingPathComponent("Transcripted", isDirectory: true)
        let defaultMeetings = transcriptedRoot
            .appendingPathComponent("captures", isDirectory: true)
            .appendingPathComponent("meetings", isDirectory: true)
        let defaultDictations = transcriptedRoot
            .appendingPathComponent("captures", isDirectory: true)
            .appendingPathComponent("dictations", isDirectory: true)
        try FileManager.default.createDirectory(at: defaultMeetings, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: defaultDictations, withIntermediateDirectories: true)

        let legacyDraftMeetings = tempHome
            .appendingPathComponent("Library", isDirectory: true)
            .appendingPathComponent("Application Support", isDirectory: true)
            .appendingPathComponent("Draft", isDirectory: true)
            .appendingPathComponent("meetings", isDirectory: true)
            .appendingPathComponent("transcripts", isDirectory: true)
        let legacyDraftDictations = tempHome
            .appendingPathComponent("Library", isDirectory: true)
            .appendingPathComponent("Application Support", isDirectory: true)
            .appendingPathComponent("Draft", isDirectory: true)
            .appendingPathComponent("dictations", isDirectory: true)
            .appendingPathComponent("transcripts", isDirectory: true)
        try FileManager.default.createDirectory(at: legacyDraftMeetings, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: legacyDraftDictations, withIntermediateDirectories: true)
        try "# Old meeting".write(to: legacyDraftMeetings.appendingPathComponent("Call_old.md"), atomically: true, encoding: .utf8)
        try "# Old dictation".write(to: legacyDraftDictations.appendingPathComponent("Dictations_2026-04-07.md"), atomically: true, encoding: .utf8)

        let directories = CLIContextDirectories.resolve(
            dataDir: nil,
            meetingsDir: nil,
            dictationsDir: nil,
            environment: [:],
            fileManager: .default,
            homeDirectory: tempHome
        )

        XCTAssertEqual(directories.meetingDirs.map(\.standardizedFileURL.path), [
            defaultMeetings.standardizedFileURL.path,
            legacyDraftMeetings.standardizedFileURL.path,
        ])
        XCTAssertEqual(directories.dictationDirs.map(\.standardizedFileURL.path), [
            defaultDictations.standardizedFileURL.path,
            legacyDraftDictations.standardizedFileURL.path,
        ])
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

    func testResolveExplicitOverridesDoNotAddLegacyFolders() throws {
        let tempHome = makeTempDir()
        defer { removeTempDir(tempHome) }

        let overrideMeetings = tempHome.appendingPathComponent("override-meetings", isDirectory: true)
        let overrideDictations = tempHome.appendingPathComponent("override-dictations", isDirectory: true)
        let legacyDraftMeetings = tempHome
            .appendingPathComponent("Library", isDirectory: true)
            .appendingPathComponent("Application Support", isDirectory: true)
            .appendingPathComponent("Draft", isDirectory: true)
            .appendingPathComponent("meetings", isDirectory: true)
            .appendingPathComponent("transcripts", isDirectory: true)
        try FileManager.default.createDirectory(at: legacyDraftMeetings, withIntermediateDirectories: true)
        try "# Old meeting".write(to: legacyDraftMeetings.appendingPathComponent("Call_old.md"), atomically: true, encoding: .utf8)

        let directories = CLIContextDirectories.resolve(
            dataDir: nil,
            meetingsDir: overrideMeetings.path,
            dictationsDir: overrideDictations.path,
            environment: [:],
            fileManager: .default,
            homeDirectory: tempHome
        )

        XCTAssertEqual(directories.meetingDirs.map(\.standardizedFileURL.path), [
            overrideMeetings.standardizedFileURL.path,
        ])
        XCTAssertEqual(directories.dictationDirs.map(\.standardizedFileURL.path), [
            overrideDictations.standardizedFileURL.path,
        ])
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
