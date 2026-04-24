import XCTest
@testable import transcripted_mcp

final class DataDirectoriesTests: XCTestCase {
    var homeDir: URL!

    override func setUp() {
        super.setUp()
        homeDir = makeTempDir()
    }

    override func tearDown() {
        removeTempDir(homeDir)
        super.tearDown()
    }

    func testDefaultResolverIncludesLegacyDraftMarkdownWhenNewFoldersExist() throws {
        let paths = makePaths(in: homeDir)
        try FileManager.default.createDirectory(at: paths.defaultMeetings, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: paths.defaultDictations, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: paths.legacyDraftMeetings, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: paths.legacyDraftDictations, withIntermediateDirectories: true)
        try "# Old meeting".write(to: paths.legacyDraftMeetings.appendingPathComponent("Call_old.md"), atomically: true, encoding: .utf8)
        try "# Old dictation".write(to: paths.legacyDraftDictations.appendingPathComponent("Dictations_2026-04-07.md"), atomically: true, encoding: .utf8)

        let directories = TranscriptedDataDirectories.resolve(
            environment: [:],
            fileManager: .default,
            homeDirectory: homeDir
        )

        XCTAssertEqual(directories.meetingDirs.map(\.standardizedFileURL.path), [
            paths.defaultMeetings.standardizedFileURL.path,
            paths.legacyDraftMeetings.standardizedFileURL.path,
        ])
        XCTAssertEqual(directories.dictationDirs.map(\.standardizedFileURL.path), [
            paths.defaultDictations.standardizedFileURL.path,
            paths.legacyDraftDictations.standardizedFileURL.path,
        ])
    }

    func testExplicitOverridesDoNotAddLegacyFolders() throws {
        let paths = makePaths(in: homeDir)
        let overrideMeetings = homeDir.appendingPathComponent("override-meetings", isDirectory: true)
        let overrideDictations = homeDir.appendingPathComponent("override-dictations", isDirectory: true)
        try FileManager.default.createDirectory(at: paths.legacyDraftMeetings, withIntermediateDirectories: true)
        try "# Old meeting".write(to: paths.legacyDraftMeetings.appendingPathComponent("Call_old.md"), atomically: true, encoding: .utf8)

        let directories = TranscriptedDataDirectories.resolve(
            environment: [
                "TRANSCRIPTED_MEETINGS_DIR": overrideMeetings.path,
                "TRANSCRIPTED_DICTATIONS_DIR": overrideDictations.path,
            ],
            fileManager: .default,
            homeDirectory: homeDir
        )

        XCTAssertEqual(directories.meetingDirs.map(\.standardizedFileURL.path), [
            overrideMeetings.standardizedFileURL.path,
        ])
        XCTAssertEqual(directories.dictationDirs.map(\.standardizedFileURL.path), [
            overrideDictations.standardizedFileURL.path,
        ])
    }

    private func makePaths(in home: URL) -> TestCapturePaths {
        let appSupport = home
            .appendingPathComponent("Library", isDirectory: true)
            .appendingPathComponent("Application Support", isDirectory: true)
        let defaultCaptures = appSupport
            .appendingPathComponent("Transcripted", isDirectory: true)
            .appendingPathComponent("captures", isDirectory: true)
        let draftRoot = appSupport.appendingPathComponent("Draft", isDirectory: true)

        return TestCapturePaths(
            defaultMeetings: defaultCaptures.appendingPathComponent("meetings", isDirectory: true),
            defaultDictations: defaultCaptures.appendingPathComponent("dictations", isDirectory: true),
            legacyDraftMeetings: draftRoot
                .appendingPathComponent("meetings", isDirectory: true)
                .appendingPathComponent("transcripts", isDirectory: true),
            legacyDraftDictations: draftRoot
                .appendingPathComponent("dictations", isDirectory: true)
                .appendingPathComponent("transcripts", isDirectory: true)
        )
    }

    private struct TestCapturePaths {
        let defaultMeetings: URL
        let defaultDictations: URL
        let legacyDraftMeetings: URL
        let legacyDraftDictations: URL
    }
}
