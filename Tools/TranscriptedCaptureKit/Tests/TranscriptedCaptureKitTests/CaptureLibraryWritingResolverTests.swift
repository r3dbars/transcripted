import XCTest
@testable import TranscriptedCaptureKit

/// Writing-folder resolution: `<capture-library>/writing`, following every
/// rule meetings and dictations follow except the legacy fallbacks (writing
/// has no Draft-era location). All fixtures live under a temp home.
final class CaptureLibraryWritingResolverTests: XCTestCase {
    private var tempHome: URL!

    override func setUpWithError() throws {
        tempHome = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: tempHome, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: tempHome)
    }

    func testDefaultWritingDirIsBesideMeetingsAndDictations() {
        let resolved = CaptureLibraryResolver.resolve(environment: [:], homeDirectory: tempHome)

        XCTAssertEqual(paths(resolved.writingDirs), [
            path("Library/Application Support/Transcripted/captures/writing"),
        ])
        XCTAssertEqual(resolved.resolutionSource, .defaultCaptures)
    }

    func testWritingEnvOverrideWinsAndReportsKindOverride() {
        let override = tempHome.appendingPathComponent("my-writing", isDirectory: true)
        let resolved = CaptureLibraryResolver.resolve(
            environment: ["TRANSCRIPTED_WRITING_DIR": override.path],
            homeDirectory: tempHome
        )

        XCTAssertEqual(paths(resolved.writingDirs), [override.standardizedFileURL.path])
        XCTAssertEqual(
            paths(resolved.meetingDirs),
            [path("Library/Application Support/Transcripted/captures/meetings")],
            "overriding writing leaves the other kinds on the normal chain"
        )
        XCTAssertEqual(resolved.resolutionSource, .envKindDirs)
    }

    func testExplicitWritingDirWinsOverEnvironment() {
        let explicit = tempHome.appendingPathComponent("explicit-writing", isDirectory: true)
        let env = tempHome.appendingPathComponent("env-writing", isDirectory: true)
        let resolved = CaptureLibraryResolver.resolve(
            writingDir: explicit.path,
            environment: ["TRANSCRIPTED_WRITING_DIR": env.path],
            homeDirectory: tempHome
        )

        XCTAssertEqual(paths(resolved.writingDirs), [explicit.standardizedFileURL.path])
    }

    func testEmptyWritingEnvOverrideIsIgnored() {
        let resolved = CaptureLibraryResolver.resolve(
            environment: ["TRANSCRIPTED_WRITING_DIR": ""],
            homeDirectory: tempHome
        )

        XCTAssertEqual(paths(resolved.writingDirs), [
            path("Library/Application Support/Transcripted/captures/writing"),
        ])
        XCTAssertEqual(resolved.resolutionSource, .defaultCaptures)
    }

    func testSharedDataDirWithSubfoldersUsesWritingSubfolder() throws {
        let sharedRoot = tempHome.appendingPathComponent("shared", isDirectory: true)
        try FileManager.default.createDirectory(
            at: sharedRoot.appendingPathComponent("writing", isDirectory: true),
            withIntermediateDirectories: true
        )

        let resolved = CaptureLibraryResolver.resolve(
            environment: [
                "TRANSCRIPTED_DATA_DIR": sharedRoot.path,
                "TRANSCRIPTED_WRITING_DIR": tempHome.appendingPathComponent("ignored").path,
            ],
            homeDirectory: tempHome
        )

        XCTAssertEqual(paths(resolved.writingDirs), [
            sharedRoot.appendingPathComponent("writing").standardizedFileURL.path,
        ], "the shared data dir wins over per-kind overrides, and a writing/ subfolder alone selects subfolder mode")
        XCTAssertEqual(paths(resolved.meetingDirs), [
            sharedRoot.appendingPathComponent("meetings").standardizedFileURL.path,
        ])
        XCTAssertEqual(resolved.resolutionSource, .envDataDir)
    }

    func testFlatSharedDataDirReadsWritingFromTheRoot() throws {
        let sharedRoot = tempHome.appendingPathComponent("flat", isDirectory: true)
        try FileManager.default.createDirectory(at: sharedRoot, withIntermediateDirectories: true)

        let resolved = CaptureLibraryResolver.resolve(dataDir: sharedRoot.path, homeDirectory: tempHome)

        XCTAssertEqual(paths(resolved.writingDirs), [sharedRoot.standardizedFileURL.path])
        XCTAssertEqual(paths(resolved.meetingDirs), [sharedRoot.standardizedFileURL.path])
        XCTAssertEqual(resolved.sharedDataRoot?.standardizedFileURL.path, sharedRoot.standardizedFileURL.path)
    }

    func testManifestWithoutWritingKeyDerivesWritingFromCaptureLibrary() throws {
        let library = tempHome.appendingPathComponent("custom-captures", isDirectory: true)
        try writeManifest(library: library, writing: nil)

        let resolved = CaptureLibraryResolver.resolve(environment: [:], homeDirectory: tempHome)

        XCTAssertEqual(resolved.resolutionSource, .appManifest)
        XCTAssertEqual(paths(resolved.writingDirs), [
            library.appendingPathComponent("writing").standardizedFileURL.path,
        ])
    }

    func testManifestWritingKeyIsUsedWhenValid() throws {
        let library = tempHome.appendingPathComponent("custom-captures", isDirectory: true)
        try writeManifest(library: library, writing: library.appendingPathComponent("writing").path)

        let resolved = CaptureLibraryResolver.resolve(environment: [:], homeDirectory: tempHome)

        XCTAssertEqual(resolved.resolutionSource, .appManifest)
        XCTAssertEqual(paths(resolved.writingDirs), [
            library.appendingPathComponent("writing").standardizedFileURL.path,
        ])
    }

    func testManifestWithMisplacedWritingKeyIsRejected() throws {
        let library = tempHome.appendingPathComponent("custom-captures", isDirectory: true)
        try writeManifest(library: library, writing: tempHome.appendingPathComponent("elsewhere/writing").path)

        let resolved = CaptureLibraryResolver.resolve(environment: [:], homeDirectory: tempHome)

        XCTAssertEqual(resolved.resolutionSource, .defaultCaptures, "a writing path outside the library invalidates the manifest")
        XCTAssertEqual(paths(resolved.writingDirs), [
            path("Library/Application Support/Transcripted/captures/writing"),
        ])
    }

    func testPreferenceDerivesWritingFromCaptureLibrary() throws {
        let preferencesDir = tempHome.appendingPathComponent("Library/Preferences", isDirectory: true)
        let library = tempHome.appendingPathComponent("preferred-captures", isDirectory: true)
        try FileManager.default.createDirectory(at: preferencesDir, withIntermediateDirectories: true)
        let plistData = try PropertyListSerialization.data(
            fromPropertyList: ["transcriptSaveLocation": library.path],
            format: .xml,
            options: 0
        )
        try plistData.write(to: preferencesDir.appendingPathComponent("app.transcripted.Transcripted.plist"))

        let resolved = CaptureLibraryResolver.resolve(environment: [:], homeDirectory: tempHome)

        XCTAssertEqual(resolved.resolutionSource, .appPreference)
        XCTAssertEqual(paths(resolved.writingDirs), [
            library.appendingPathComponent("writing").standardizedFileURL.path,
        ])
    }

    func testRealAppWrittenManifestFixtureStillDecodesWithWritingDerived() throws {
        // golden.json predates Writing and has no writingDirectory key; it must
        // still decode, with writing derived from captureLibraryDirectory.
        let fixtureURL = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("Tests/Fixtures/mcp-directories-manifest/golden.json")
        let fixtureData = try Data(contentsOf: fixtureURL)
        let root = tempHome.appendingPathComponent("Library/Application Support/Transcripted", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try fixtureData.write(to: root.appendingPathComponent("mcp-directories.json"))

        struct Golden: Decodable { let captureLibraryDirectory: String }
        let golden = try JSONDecoder().decode(Golden.self, from: fixtureData)

        let resolved = CaptureLibraryResolver.resolve(environment: [:], homeDirectory: tempHome)

        XCTAssertEqual(resolved.resolutionSource, .appManifest)
        XCTAssertEqual(paths(resolved.writingDirs), [
            URL(fileURLWithPath: golden.captureLibraryDirectory)
                .appendingPathComponent("writing").standardizedFileURL.path,
        ])
    }

    // MARK: - Helpers

    private func writeManifest(library: URL, writing: String?) throws {
        let root = tempHome.appendingPathComponent("Library/Application Support/Transcripted", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        var manifest: [String: Any] = [
            "version": 1,
            "captureLibraryDirectory": library.path,
            "meetingsDirectory": library.appendingPathComponent("meetings").path,
            "dictationsDirectory": library.appendingPathComponent("dictations").path,
            "updatedAt": "1970-01-01T00:00:00Z",
        ]
        if let writing {
            manifest["writingDirectory"] = writing
        }
        let data = try JSONSerialization.data(withJSONObject: manifest)
        try data.write(to: root.appendingPathComponent("mcp-directories.json"))
    }

    private func paths(_ urls: [URL]) -> [String] {
        urls.map(\.standardizedFileURL.path)
    }

    private func path(_ relative: String) -> String {
        tempHome.appendingPathComponent(relative).standardizedFileURL.path
    }
}
