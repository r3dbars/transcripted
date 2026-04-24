import XCTest
@testable import transcripted_mcp

final class DataDirectoriesTests: XCTestCase {
    var tempHome: URL!

    override func setUp() {
        super.setUp()
        tempHome = makeTempDir()
    }

    override func tearDown() {
        removeTempDir(tempHome)
        super.tearDown()
    }

    func testResolvePrefersCurrentTranscriptedLayoutWhenOnlyDictationsExist() throws {
        let transcriptedRoot = tempHome
            .appendingPathComponent("Library", isDirectory: true)
            .appendingPathComponent("Application Support", isDirectory: true)
            .appendingPathComponent("Transcripted", isDirectory: true)
        let dictationsDir = transcriptedRoot
            .appendingPathComponent("captures", isDirectory: true)
            .appendingPathComponent("dictations", isDirectory: true)
        try FileManager.default.createDirectory(at: dictationsDir, withIntermediateDirectories: true)

        let draftMeetingsDir = tempHome
            .appendingPathComponent("Library", isDirectory: true)
            .appendingPathComponent("Application Support", isDirectory: true)
            .appendingPathComponent("Draft", isDirectory: true)
            .appendingPathComponent("meetings", isDirectory: true)
            .appendingPathComponent("transcripts", isDirectory: true)
        try FileManager.default.createDirectory(at: draftMeetingsDir, withIntermediateDirectories: true)

        let directories = TranscriptedDataDirectories.resolve(
            environment: [:],
            fileManager: .default,
            homeDirectory: tempHome
        )

        XCTAssertEqual(
            directories.meetingsDir.path,
            transcriptedRoot
                .appendingPathComponent("captures", isDirectory: true)
                .appendingPathComponent("meetings", isDirectory: true)
                .path
        )
        XCTAssertEqual(directories.dictationsDir.path, dictationsDir.path)
    }

    func testResolveIncludesLegacyDraftMarkdownAfterCurrentDefaults() throws {
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

        let directories = TranscriptedDataDirectories.resolve(
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

    func testResolveExplicitOverridesDoNotAddLegacyFolders() throws {
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

        let directories = TranscriptedDataDirectories.resolve(
            environment: [
                "TRANSCRIPTED_MEETINGS_DIR": overrideMeetings.path,
                "TRANSCRIPTED_DICTATIONS_DIR": overrideDictations.path,
            ],
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
}
