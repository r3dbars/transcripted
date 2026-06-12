import XCTest
@testable import TranscriptedCaptureKit

final class CaptureLibraryResolverTests: XCTestCase {
    func testResolveIncludesLegacyDraftMarkdownAfterCurrentDefaults() throws {
        let tempHome = makeTempDir()
        defer { removeTempDir(tempHome) }

        let defaultMeetings = tempHome.appendingPathComponent(
            "Library/Application Support/Transcripted/captures/meetings", isDirectory: true)
        let legacyDraftMeetings = tempHome.appendingPathComponent(
            "Library/Application Support/Draft/meetings/transcripts", isDirectory: true)
        try FileManager.default.createDirectory(at: defaultMeetings, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: legacyDraftMeetings, withIntermediateDirectories: true)
        try sampleMeetingMarkdown.write(
            to: legacyDraftMeetings.appendingPathComponent("Call_old.md"),
            atomically: true,
            encoding: .utf8
        )

        let resolved = CaptureLibraryResolver.resolve(
            environment: [:],
            fileManager: .default,
            homeDirectory: tempHome
        )

        XCTAssertEqual(resolved.meetingDirs.map(\.standardizedFileURL.path), [
            defaultMeetings.standardizedFileURL.path,
            legacyDraftMeetings.standardizedFileURL.path,
        ])
        XCTAssertNil(resolved.sharedDataRoot)
    }

    func testResolveSkipsLegacyCandidatesWithoutCaptureMarkdown() throws {
        let tempHome = makeTempDir()
        defer { removeTempDir(tempHome) }

        let legacyShared = tempHome.appendingPathComponent("Documents/Transcripted", isDirectory: true)
        try FileManager.default.createDirectory(at: legacyShared, withIntermediateDirectories: true)
        try "# Notes".write(to: legacyShared.appendingPathComponent("CLAUDE.md"), atomically: true, encoding: .utf8)

        let resolved = CaptureLibraryResolver.resolve(
            environment: [:],
            fileManager: .default,
            homeDirectory: tempHome
        )

        XCTAssertFalse(resolved.meetingDirs.map(\.standardizedFileURL.path)
            .contains(legacyShared.standardizedFileURL.path))
        XCTAssertFalse(resolved.dictationDirs.map(\.standardizedFileURL.path)
            .contains(legacyShared.standardizedFileURL.path))
    }

    func testResolveIncludesSymlinkedLegacyDirectoryWithCaptureMarkdown() throws {
        let tempHome = makeTempDir()
        let realLibrary = makeTempDir()
        defer {
            removeTempDir(tempHome)
            removeTempDir(realLibrary)
        }

        try sampleMeetingMarkdown.write(
            to: realLibrary.appendingPathComponent("Shared meeting.md"),
            atomically: true,
            encoding: .utf8
        )

        let documents = tempHome.appendingPathComponent("Documents", isDirectory: true)
        try FileManager.default.createDirectory(at: documents, withIntermediateDirectories: true)
        let legacyShared = documents.appendingPathComponent("Transcripted", isDirectory: true)
        try FileManager.default.createSymbolicLink(at: legacyShared, withDestinationURL: realLibrary)

        let resolved = CaptureLibraryResolver.resolve(
            environment: [:],
            fileManager: .default,
            homeDirectory: tempHome
        )

        XCTAssertTrue(resolved.meetingDirs.map(\.standardizedFileURL.path)
            .contains(legacyShared.standardizedFileURL.path))
    }

    func testResolveSharedDataDirUsesSubfoldersAndReportsSharedRoot() throws {
        let tempHome = makeTempDir()
        defer { removeTempDir(tempHome) }

        let sharedRoot = tempHome.appendingPathComponent("shared-context", isDirectory: true)
        try FileManager.default.createDirectory(
            at: sharedRoot.appendingPathComponent("meetings", isDirectory: true),
            withIntermediateDirectories: true
        )

        let resolved = CaptureLibraryResolver.resolve(
            environment: ["TRANSCRIPTED_DATA_DIR": sharedRoot.path],
            fileManager: .default,
            homeDirectory: tempHome
        )

        XCTAssertEqual(resolved.meetingDirs.map(\.standardizedFileURL.path), [
            sharedRoot.appendingPathComponent("meetings", isDirectory: true).standardizedFileURL.path,
        ])
        XCTAssertEqual(resolved.dictationDirs.map(\.standardizedFileURL.path), [
            sharedRoot.appendingPathComponent("dictations", isDirectory: true).standardizedFileURL.path,
        ])
        XCTAssertEqual(resolved.sharedDataRoot?.standardizedFileURL.path, sharedRoot.standardizedFileURL.path)
    }

    func testResolveExplicitDataDirWinsOverEnvironment() throws {
        let tempHome = makeTempDir()
        defer { removeTempDir(tempHome) }

        let explicitRoot = tempHome.appendingPathComponent("explicit", isDirectory: true)
        let envRoot = tempHome.appendingPathComponent("environment", isDirectory: true)
        try FileManager.default.createDirectory(at: explicitRoot, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: envRoot, withIntermediateDirectories: true)

        let resolved = CaptureLibraryResolver.resolve(
            dataDir: explicitRoot.path,
            environment: ["TRANSCRIPTED_DATA_DIR": envRoot.path],
            fileManager: .default,
            homeDirectory: tempHome
        )

        XCTAssertEqual(resolved.meetingDirs.map(\.standardizedFileURL.path), [
            explicitRoot.standardizedFileURL.path,
        ])
        XCTAssertEqual(resolved.sharedDataRoot?.standardizedFileURL.path, explicitRoot.standardizedFileURL.path)
    }

    func testResolveExplicitPerKindOverridesSkipLegacyCandidates() throws {
        let tempHome = makeTempDir()
        defer { removeTempDir(tempHome) }

        let overrideMeetings = tempHome.appendingPathComponent("override-meetings", isDirectory: true)
        let legacyDraftMeetings = tempHome.appendingPathComponent(
            "Library/Application Support/Draft/meetings/transcripts", isDirectory: true)
        try FileManager.default.createDirectory(at: legacyDraftMeetings, withIntermediateDirectories: true)
        try sampleMeetingMarkdown.write(
            to: legacyDraftMeetings.appendingPathComponent("Call_old.md"),
            atomically: true,
            encoding: .utf8
        )

        let resolved = CaptureLibraryResolver.resolve(
            meetingsDir: overrideMeetings.path,
            environment: [:],
            fileManager: .default,
            homeDirectory: tempHome
        )

        XCTAssertEqual(resolved.meetingDirs.map(\.standardizedFileURL.path), [
            overrideMeetings.standardizedFileURL.path,
        ])
    }

    func testResolveUsesAppDirectoryManifestBeforeDefaultCaptures() throws {
        let tempHome = makeTempDir()
        defer { removeTempDir(tempHome) }

        let transcriptedRoot = tempHome.appendingPathComponent(
            "Library/Application Support/Transcripted", isDirectory: true)
        let manifestMeetings = tempHome.appendingPathComponent("custom-captures/meetings", isDirectory: true)
        let manifestDictations = tempHome.appendingPathComponent("custom-captures/dictations", isDirectory: true)
        try FileManager.default.createDirectory(at: transcriptedRoot, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: manifestMeetings, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: manifestDictations, withIntermediateDirectories: true)

        try """
        {
          "version": 1,
          "captureLibraryDirectory": "\(tempHome.appendingPathComponent("custom-captures", isDirectory: true).path)",
          "meetingsDirectory": "\(manifestMeetings.path)",
          "dictationsDirectory": "\(manifestDictations.path)"
        }
        """.write(
            to: transcriptedRoot.appendingPathComponent("mcp-directories.json"),
            atomically: true,
            encoding: .utf8
        )

        let resolved = CaptureLibraryResolver.resolve(
            environment: [:],
            fileManager: .default,
            homeDirectory: tempHome
        )

        XCTAssertEqual(resolved.meetingDirs.map(\.standardizedFileURL.path), [
            manifestMeetings.standardizedFileURL.path,
        ])
        XCTAssertEqual(resolved.dictationDirs.map(\.standardizedFileURL.path), [
            manifestDictations.standardizedFileURL.path,
        ])
    }

    func testResolveUsesAppCaptureLibraryPreferenceWhenManifestIsMissing() throws {
        let tempHome = makeTempDir()
        defer { removeTempDir(tempHome) }

        let preferencesDir = tempHome.appendingPathComponent("Library/Preferences", isDirectory: true)
        let customCaptureLibrary = tempHome.appendingPathComponent("preferred-captures", isDirectory: true)
        try FileManager.default.createDirectory(at: preferencesDir, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(
            at: customCaptureLibrary.appendingPathComponent("meetings", isDirectory: true),
            withIntermediateDirectories: true
        )

        let plistData = try PropertyListSerialization.data(
            fromPropertyList: ["transcriptSaveLocation": customCaptureLibrary.path],
            format: .xml,
            options: 0
        )
        try plistData.write(to: preferencesDir.appendingPathComponent("app.transcripted.Transcripted.plist"))

        let resolved = CaptureLibraryResolver.resolve(
            environment: [:],
            fileManager: .default,
            homeDirectory: tempHome
        )

        XCTAssertEqual(resolved.meetingDirs.map(\.standardizedFileURL.path), [
            customCaptureLibrary.appendingPathComponent("meetings", isDirectory: true).standardizedFileURL.path,
        ])
        XCTAssertEqual(resolved.dictationDirs.map(\.standardizedFileURL.path), [
            customCaptureLibrary.appendingPathComponent("dictations", isDirectory: true).standardizedFileURL.path,
        ])
    }

    private let sampleMeetingMarkdown = """
    ---
    capture_type: meeting
    date: 2026-04-07
    time: 09:00:00
    ---

    # Old meeting
    """

    private func makeTempDir() -> URL {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try! FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    private func removeTempDir(_ dir: URL) {
        try? FileManager.default.removeItem(at: dir)
    }
}
