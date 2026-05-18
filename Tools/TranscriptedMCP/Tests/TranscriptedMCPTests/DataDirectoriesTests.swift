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

    func testResolveSharedDataDirUsesMeetingsAndDictationsSubfoldersAndSharedIndex() throws {
        let sharedRoot = tempHome.appendingPathComponent("shared-context", isDirectory: true)
        let sharedMeetings = sharedRoot.appendingPathComponent("meetings", isDirectory: true)
        let sharedDictations = sharedRoot.appendingPathComponent("dictations", isDirectory: true)
        try FileManager.default.createDirectory(at: sharedMeetings, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: sharedDictations, withIntermediateDirectories: true)

        let directories = TranscriptedDataDirectories.resolve(
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
        XCTAssertEqual(directories.indexDir.standardizedFileURL.path, sharedRoot.standardizedFileURL.path)
    }

    func testResolveSharedDataDirHonorsExplicitIndexOverride() throws {
        let sharedRoot = tempHome.appendingPathComponent("shared-context", isDirectory: true)
        let sharedMeetings = sharedRoot.appendingPathComponent("meetings", isDirectory: true)
        let sharedDictations = sharedRoot.appendingPathComponent("dictations", isDirectory: true)
        let customIndex = tempHome.appendingPathComponent("custom-index", isDirectory: true)
        try FileManager.default.createDirectory(at: sharedMeetings, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: sharedDictations, withIntermediateDirectories: true)

        let directories = TranscriptedDataDirectories.resolve(
            environment: [
                "TRANSCRIPTED_DATA_DIR": sharedRoot.path,
                "TRANSCRIPTED_INDEX_DIR": customIndex.path,
            ],
            fileManager: .default,
            homeDirectory: tempHome
        )

        XCTAssertEqual(directories.meetingDirs.map(\.standardizedFileURL.path), [
            sharedMeetings.standardizedFileURL.path,
        ])
        XCTAssertEqual(directories.dictationDirs.map(\.standardizedFileURL.path), [
            sharedDictations.standardizedFileURL.path,
        ])
        XCTAssertEqual(directories.indexDir.standardizedFileURL.path, customIndex.standardizedFileURL.path)
    }

    func testResolveUsesAppDirectoryManifestBeforeDefaultCaptures() throws {
        let customRoot = tempHome.appendingPathComponent("custom-captures", isDirectory: true)
        let customMeetings = customRoot.appendingPathComponent("meetings", isDirectory: true)
        let customDictations = customRoot.appendingPathComponent("dictations", isDirectory: true)
        try FileManager.default.createDirectory(at: customMeetings, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: customDictations, withIntermediateDirectories: true)

        let defaultMeetings = tempHome
            .appendingPathComponent("Library", isDirectory: true)
            .appendingPathComponent("Application Support", isDirectory: true)
            .appendingPathComponent("Transcripted", isDirectory: true)
            .appendingPathComponent("captures", isDirectory: true)
            .appendingPathComponent("meetings", isDirectory: true)
        try FileManager.default.createDirectory(at: defaultMeetings, withIntermediateDirectories: true)

        let manifestURL = tempHome
            .appendingPathComponent("Library", isDirectory: true)
            .appendingPathComponent("Application Support", isDirectory: true)
            .appendingPathComponent("Transcripted", isDirectory: true)
            .appendingPathComponent("mcp-directories.json", isDirectory: false)
        try FileManager.default.createDirectory(at: manifestURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try """
        {
          "version": 1,
          "captureLibraryDirectory": "\(customRoot.path)",
          "meetingsDirectory": "\(customMeetings.path)",
          "dictationsDirectory": "\(customDictations.path)",
          "updatedAt": "2026-05-06T00:00:00Z"
        }
        """.write(to: manifestURL, atomically: true, encoding: .utf8)

        let directories = TranscriptedDataDirectories.resolve(
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

    func testResolveIgnoresManifestWhenDirectoriesDoNotMatchCaptureLibrary() throws {
        let manifestRoot = tempHome.appendingPathComponent("manifest-captures", isDirectory: true)
        let unrelatedMeetings = tempHome.appendingPathComponent("unrelated-meetings", isDirectory: true)
        let unrelatedDictations = tempHome.appendingPathComponent("unrelated-dictations", isDirectory: true)
        let defaultCaptures = tempHome
            .appendingPathComponent("Library", isDirectory: true)
            .appendingPathComponent("Application Support", isDirectory: true)
            .appendingPathComponent("Transcripted", isDirectory: true)
            .appendingPathComponent("captures", isDirectory: true)
        let defaultMeetings = defaultCaptures.appendingPathComponent("meetings", isDirectory: true)
        let defaultDictations = defaultCaptures.appendingPathComponent("dictations", isDirectory: true)
        let manifestURL = tempHome
            .appendingPathComponent("Library", isDirectory: true)
            .appendingPathComponent("Application Support", isDirectory: true)
            .appendingPathComponent("Transcripted", isDirectory: true)
            .appendingPathComponent("mcp-directories.json", isDirectory: false)
        try FileManager.default.createDirectory(at: manifestURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try """
        {
          "version": 1,
          "captureLibraryDirectory": "\(manifestRoot.path)",
          "meetingsDirectory": "\(unrelatedMeetings.path)",
          "dictationsDirectory": "\(unrelatedDictations.path)",
          "updatedAt": "2026-05-06T00:00:00Z"
        }
        """.write(to: manifestURL, atomically: true, encoding: .utf8)

        let directories = TranscriptedDataDirectories.resolve(
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
        let customRoot = tempHome.appendingPathComponent("preference-captures", isDirectory: true)
        let preferencesURL = tempHome
            .appendingPathComponent("Library", isDirectory: true)
            .appendingPathComponent("Preferences", isDirectory: true)
            .appendingPathComponent("com.justinbetker.draft.plist", isDirectory: false)
        try FileManager.default.createDirectory(at: preferencesURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        let data = try PropertyListSerialization.data(
            fromPropertyList: ["transcriptSaveLocation": customRoot.path],
            format: .xml,
            options: 0
        )
        try data.write(to: preferencesURL)

        let directories = TranscriptedDataDirectories.resolve(
            environment: [:],
            fileManager: .default,
            homeDirectory: tempHome
        )

        XCTAssertEqual(directories.meetingDirs.map(\.standardizedFileURL.path), [
            customRoot.appendingPathComponent("meetings", isDirectory: true).standardizedFileURL.path,
        ])
        XCTAssertEqual(directories.dictationDirs.map(\.standardizedFileURL.path), [
            customRoot.appendingPathComponent("dictations", isDirectory: true).standardizedFileURL.path,
        ])
    }

    func testResolveUsesCurrentTranscriptedPreferenceDomain() throws {
        let customRoot = tempHome.appendingPathComponent("current-preference-captures", isDirectory: true)
        let customMeetings = customRoot.appendingPathComponent("meetings", isDirectory: true)
        let customDictations = customRoot.appendingPathComponent("dictations", isDirectory: true)
        let preferencesURL = tempHome
            .appendingPathComponent("Library", isDirectory: true)
            .appendingPathComponent("Preferences", isDirectory: true)
            .appendingPathComponent("app.transcripted.Transcripted.plist", isDirectory: false)
        try FileManager.default.createDirectory(at: customMeetings, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: customDictations, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: preferencesURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        let data = try PropertyListSerialization.data(
            fromPropertyList: ["transcriptSaveLocation": customRoot.path],
            format: .xml,
            options: 0
        )
        try data.write(to: preferencesURL)

        let directories = TranscriptedDataDirectories.resolve(
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

    func testResolveExplicitOverridesWinOverAppDirectoryManifest() throws {
        let manifestRoot = tempHome.appendingPathComponent("manifest-captures", isDirectory: true)
        let overrideMeetings = tempHome.appendingPathComponent("override-meetings", isDirectory: true)
        let overrideDictations = tempHome.appendingPathComponent("override-dictations", isDirectory: true)
        let manifestURL = tempHome
            .appendingPathComponent("Library", isDirectory: true)
            .appendingPathComponent("Application Support", isDirectory: true)
            .appendingPathComponent("Transcripted", isDirectory: true)
            .appendingPathComponent("mcp-directories.json", isDirectory: false)
        try FileManager.default.createDirectory(at: manifestURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try """
        {
          "version": 1,
          "captureLibraryDirectory": "\(manifestRoot.path)",
          "meetingsDirectory": "\(manifestRoot.appendingPathComponent("meetings", isDirectory: true).path)",
          "dictationsDirectory": "\(manifestRoot.appendingPathComponent("dictations", isDirectory: true).path)",
          "updatedAt": "2026-05-06T00:00:00Z"
        }
        """.write(to: manifestURL, atomically: true, encoding: .utf8)

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

    func testResolveSkipsLegacySharedFolderWithoutCaptureMarkdown() throws {
        let legacyShared = tempHome
            .appendingPathComponent("Documents", isDirectory: true)
            .appendingPathComponent("Transcripted", isDirectory: true)
        try FileManager.default.createDirectory(at: legacyShared, withIntermediateDirectories: true)
        try "# Notes".write(to: legacyShared.appendingPathComponent("CLAUDE.md"), atomically: true, encoding: .utf8)

        let directories = TranscriptedDataDirectories.resolve(
            environment: [:],
            fileManager: .default,
            homeDirectory: tempHome
        )

        XCTAssertFalse(directories.meetingDirs.map(\.standardizedFileURL.path).contains(legacyShared.standardizedFileURL.path))
        XCTAssertFalse(directories.dictationDirs.map(\.standardizedFileURL.path).contains(legacyShared.standardizedFileURL.path))
    }

    func testResolveIncludesLegacySharedFolderWithCaptureMarkdown() throws {
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

        let directories = TranscriptedDataDirectories.resolve(
            environment: [:],
            fileManager: .default,
            homeDirectory: tempHome
        )

        XCTAssertTrue(directories.meetingDirs.map(\.standardizedFileURL.path).contains(legacyShared.standardizedFileURL.path))
        XCTAssertTrue(directories.dictationDirs.map(\.standardizedFileURL.path).contains(legacyShared.standardizedFileURL.path))
    }
}
