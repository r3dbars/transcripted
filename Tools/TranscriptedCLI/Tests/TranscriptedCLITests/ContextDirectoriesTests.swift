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

    func testResolveUsesAppDirectoryManifestBeforeDefaultCaptures() throws {
        let tempHome = makeTempDir()
        defer { removeTempDir(tempHome) }

        let transcriptedRoot = tempHome
            .appendingPathComponent("Library", isDirectory: true)
            .appendingPathComponent("Application Support", isDirectory: true)
            .appendingPathComponent("Transcripted", isDirectory: true)
        let manifestMeetings = tempHome.appendingPathComponent("custom-captures/meetings", isDirectory: true)
        let manifestDictations = tempHome.appendingPathComponent("custom-captures/dictations", isDirectory: true)
        try FileManager.default.createDirectory(at: transcriptedRoot, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: manifestMeetings, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: manifestDictations, withIntermediateDirectories: true)

        let manifestURL = transcriptedRoot.appendingPathComponent("mcp-directories.json", isDirectory: false)
        try """
        {
          "version": 1,
          "captureLibraryDirectory": "\(tempHome.appendingPathComponent("custom-captures", isDirectory: true).path)",
          "meetingsDirectory": "\(manifestMeetings.path)",
          "dictationsDirectory": "\(manifestDictations.path)"
        }
        """.write(to: manifestURL, atomically: true, encoding: .utf8)

        let directories = CLIContextDirectories.resolve(
            dataDir: nil,
            meetingsDir: nil,
            dictationsDir: nil,
            environment: [:],
            fileManager: .default,
            homeDirectory: tempHome
        )

        XCTAssertEqual(directories.meetingDirs.map(\.standardizedFileURL.path), [
            manifestMeetings.standardizedFileURL.path,
        ])
        XCTAssertEqual(directories.dictationDirs.map(\.standardizedFileURL.path), [
            manifestDictations.standardizedFileURL.path,
        ])
    }

    func testResolveIgnoresManifestWhenDirectoriesDoNotMatchCaptureLibrary() throws {
        let tempHome = makeTempDir()
        defer { removeTempDir(tempHome) }

        let transcriptedRoot = tempHome
            .appendingPathComponent("Library", isDirectory: true)
            .appendingPathComponent("Application Support", isDirectory: true)
            .appendingPathComponent("Transcripted", isDirectory: true)
        let manifestRoot = tempHome.appendingPathComponent("manifest-captures", isDirectory: true)
        let unrelatedMeetings = tempHome.appendingPathComponent("unrelated-meetings", isDirectory: true)
        let unrelatedDictations = tempHome.appendingPathComponent("unrelated-dictations", isDirectory: true)
        let defaultCaptures = transcriptedRoot.appendingPathComponent("captures", isDirectory: true)
        let defaultMeetings = defaultCaptures.appendingPathComponent("meetings", isDirectory: true)
        let defaultDictations = defaultCaptures.appendingPathComponent("dictations", isDirectory: true)
        try FileManager.default.createDirectory(at: transcriptedRoot, withIntermediateDirectories: true)

        let manifestURL = transcriptedRoot.appendingPathComponent("mcp-directories.json", isDirectory: false)
        try """
        {
          "version": 1,
          "captureLibraryDirectory": "\(manifestRoot.path)",
          "meetingsDirectory": "\(unrelatedMeetings.path)",
          "dictationsDirectory": "\(unrelatedDictations.path)"
        }
        """.write(to: manifestURL, atomically: true, encoding: .utf8)

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
        ])
        XCTAssertEqual(directories.dictationDirs.map(\.standardizedFileURL.path), [
            defaultDictations.standardizedFileURL.path,
        ])
    }

    func testResolveUsesAppCaptureLibraryPreferenceWhenManifestIsMissing() throws {
        let tempHome = makeTempDir()
        defer { removeTempDir(tempHome) }

        let preferencesDir = tempHome
            .appendingPathComponent("Library", isDirectory: true)
            .appendingPathComponent("Preferences", isDirectory: true)
        let customCaptureLibrary = tempHome.appendingPathComponent("preferred-captures", isDirectory: true)
        let customMeetings = customCaptureLibrary.appendingPathComponent("meetings", isDirectory: true)
        let customDictations = customCaptureLibrary.appendingPathComponent("dictations", isDirectory: true)
        try FileManager.default.createDirectory(at: preferencesDir, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: customMeetings, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: customDictations, withIntermediateDirectories: true)

        let plistURL = preferencesDir.appendingPathComponent("app.transcripted.Transcripted.plist", isDirectory: false)
        let plistData = try PropertyListSerialization.data(
            fromPropertyList: ["transcriptSaveLocation": customCaptureLibrary.path],
            format: .xml,
            options: 0
        )
        try plistData.write(to: plistURL)

        let directories = CLIContextDirectories.resolve(
            dataDir: nil,
            meetingsDir: nil,
            dictationsDir: nil,
            environment: [:],
            fileManager: .default,
            homeDirectory: tempHome
        )

        XCTAssertEqual(directories.meetingDirs.map(\.standardizedFileURL.path), [
            customMeetings.standardizedFileURL.path,
        ])
        XCTAssertEqual(directories.dictationDirs.map(\.standardizedFileURL.path), [
            customDictations.standardizedFileURL.path,
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
