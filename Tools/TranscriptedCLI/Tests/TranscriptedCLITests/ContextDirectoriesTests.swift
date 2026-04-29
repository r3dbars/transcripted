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
        try """
        ---
        capture_type: meeting
        date: 2026-04-07
        time: 09:00:00
        ---

        # Old meeting
        """.write(
            to: legacyDraftMeetings.appendingPathComponent("Call_old.md"),
            atomically: true,
            encoding: .utf8
        )
        try """
        ---
        capture_type: dictation_day
        date: 2026-04-07
        ---

        # Old dictation
        """.write(
            to: legacyDraftDictations.appendingPathComponent("Dictations_2026-04-07.md"),
            atomically: true,
            encoding: .utf8
        )

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
        try """
        ---
        capture_type: meeting
        date: 2026-04-07
        time: 09:00:00
        ---

        # Old meeting
        """.write(
            to: legacyDraftMeetings.appendingPathComponent("Call_old.md"),
            atomically: true,
            encoding: .utf8
        )

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

    func testResolveSharedDataDirUsesMeetingsAndDictationsSubfolders() throws {
        let tempHome = makeTempDir()
        defer { removeTempDir(tempHome) }

        let sharedRoot = tempHome.appendingPathComponent("shared-context", isDirectory: true)
        let sharedMeetings = sharedRoot.appendingPathComponent("meetings", isDirectory: true)
        let sharedDictations = sharedRoot.appendingPathComponent("dictations", isDirectory: true)
        try FileManager.default.createDirectory(at: sharedMeetings, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: sharedDictations, withIntermediateDirectories: true)

        let directories = CLIContextDirectories.resolve(
            dataDir: nil,
            meetingsDir: nil,
            dictationsDir: nil,
            environment: ["TRANSCRIPTED_DATA_DIR": sharedRoot.path],
            fileManager: .default,
            homeDirectory: tempHome
        )

        XCTAssertEqual(directories.meetingDirs.map(\.standardizedFileURL.path), [
            sharedMeetings.standardizedFileURL.path,
        ])
        XCTAssertEqual(directories.dictationDirs.map(\.standardizedFileURL.path), [
            sharedDictations.standardizedFileURL.path,
        ])
    }

    func testResolveSkipsLegacySharedFolderWithoutCaptureMarkdown() throws {
        let tempHome = makeTempDir()
        defer { removeTempDir(tempHome) }

        let legacyShared = tempHome
            .appendingPathComponent("Documents", isDirectory: true)
            .appendingPathComponent("Transcripted", isDirectory: true)
        try FileManager.default.createDirectory(at: legacyShared, withIntermediateDirectories: true)
        try "# Notes".write(to: legacyShared.appendingPathComponent("CLAUDE.md"), atomically: true, encoding: .utf8)

        let directories = CLIContextDirectories.resolve(
            dataDir: nil,
            meetingsDir: nil,
            dictationsDir: nil,
            environment: [:],
            fileManager: .default,
            homeDirectory: tempHome
        )

        XCTAssertFalse(directories.meetingDirs.map(\.standardizedFileURL.path).contains(legacyShared.standardizedFileURL.path))
        XCTAssertFalse(directories.dictationDirs.map(\.standardizedFileURL.path).contains(legacyShared.standardizedFileURL.path))
    }

    func testResolveIncludesLegacySharedFolderWithCaptureMarkdown() throws {
        let tempHome = makeTempDir()
        defer { removeTempDir(tempHome) }

        let legacyShared = tempHome
            .appendingPathComponent("Documents", isDirectory: true)
            .appendingPathComponent("Transcripted", isDirectory: true)
        try FileManager.default.createDirectory(at: legacyShared, withIntermediateDirectories: true)
        try """
        ---
        capture_type: meeting
        date: 2026-04-20
        time: 09:00:00
        ---

        # Shared meeting
        """.write(
            to: legacyShared.appendingPathComponent("Shared meeting.md"),
            atomically: true,
            encoding: .utf8
        )

        let directories = CLIContextDirectories.resolve(
            dataDir: nil,
            meetingsDir: nil,
            dictationsDir: nil,
            environment: [:],
            fileManager: .default,
            homeDirectory: tempHome
        )

        XCTAssertTrue(directories.meetingDirs.map(\.standardizedFileURL.path).contains(legacyShared.standardizedFileURL.path))
        XCTAssertTrue(directories.dictationDirs.map(\.standardizedFileURL.path).contains(legacyShared.standardizedFileURL.path))
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
