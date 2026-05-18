import XCTest
@testable import transcripted_mcp

final class TranscriptLoaderTests: XCTestCase {
    var tempDir: URL!

    override func setUp() {
        super.setUp()
        tempDir = makeTempDir()
    }

    override func tearDown() {
        removeTempDir(tempDir)
        super.tearDown()
    }

    func testLoadValidMarkdown() throws {
        let fixture = makeFixtureJSON()
        try writeFixture(fixture, filename: "Call_test", to: tempDir)

        let transcript = TranscriptLoader.load(tempDir.appendingPathComponent("Call_test.md"))
        XCTAssertNotNil(transcript)
        XCTAssertEqual(transcript?.version, "2.0")
        XCTAssertEqual(transcript?.utterances.count, 2)
        XCTAssertEqual(transcript?.speakers.count, 2)
    }

    func testLoadDuplicateSpeakerNamesDoesNotCrash() throws {
        let fixture = makeFixtureJSON(
            speakers: [
                ("mic_0", "You", nil),
                ("system_0", "Alex", "80FB272B-6061-4FC4-8408-3F7A974C59DB"),
                ("system_1", "Alex", "4F57C98D-B6B7-449F-95B9-3521FA99D7DA"),
            ],
            utterances: [
                ("system_0", 0.0, 4.0, "First speaker with the shared display name."),
                ("system_1", 4.0, 8.0, "Second speaker with the shared display name."),
            ]
        )
        try writeFixture(fixture, filename: "Call_duplicate_names", to: tempDir)

        let transcript = TranscriptLoader.load(tempDir.appendingPathComponent("Call_duplicate_names.md"))

        XCTAssertNotNil(transcript)
        XCTAssertEqual(transcript?.utterances.count, 2)
    }

    func testLoadMalformedMarkdownReturnsNil() throws {
        try "not markdown at all".write(to: tempDir.appendingPathComponent("Call_bad.md"), atomically: true, encoding: .utf8)
        let transcript = TranscriptLoader.load(tempDir.appendingPathComponent("Call_bad.md"))
        XCTAssertNil(transcript)
    }

    func testLoadMeetingSkipsMalformedLegacyTranscriptRows() throws {
        let markdown = """
        ---
        capture_type: meeting
        date: 2026-04-18
        time: 09:15:00
        duration: "0:18"
        ---

        # Parser fixture

        ## Full Transcript

        [00:00]
        [00:01]x
        [00:02] [
        [00:03] [Mic/You] Still works.
        """
        try markdown.write(to: tempDir.appendingPathComponent("Call_malformed_legacy.md"), atomically: true, encoding: .utf8)

        let transcript = TranscriptLoader.load(tempDir.appendingPathComponent("Call_malformed_legacy.md"))

        XCTAssertNotNil(transcript)
        XCTAssertEqual(transcript?.utterances.count, 1)
        XCTAssertEqual(transcript?.utterances.first?.text, "Still works.")
    }

    func testMalformedDurationFallsBackToZero() throws {
        for (filename, duration) in [
            ("Call_bad_text_duration", "1:bad"),
            ("Call_negative_duration", "-1:02"),
        ] {
            let markdown = """
            ---
            capture_type: meeting
            date: 2026-04-18
            time: 09:15:00
            duration: "\(duration)"
            ---

            # Parser fixture

            ## Full Transcript

            [00:03] [Mic/You] Still works.
            """
            try markdown.write(to: tempDir.appendingPathComponent("\(filename).md"), atomically: true, encoding: .utf8)

            let transcript = TranscriptLoader.load(tempDir.appendingPathComponent("\(filename).md"))

            XCTAssertEqual(transcript?.recording.durationSeconds, 0)
        }
    }

    func testLoadMissingFileReturnsNil() {
        let transcript = TranscriptLoader.load(tempDir.appendingPathComponent("Call_missing.md"))
        XCTAssertNil(transcript)
    }

    func testEnumerateArtifacts() throws {
        try writeFixture(makeFixtureJSON(), filename: "Call_2026-03-29_10-00-00", to: tempDir)
        try writeFixture(makeFixtureJSON(), filename: "Call_2026-03-30_10-00-00", to: tempDir)
        try writeFixture(makeDictationDayJSON(), filename: "Dictations_2026-04-07", to: tempDir)
        try "other file".data(using: .utf8)!.write(to: tempDir.appendingPathComponent("notes.json"))
        try "not json".data(using: .utf8)!.write(to: tempDir.appendingPathComponent("readme.txt"))
        try "# Notes".write(to: tempDir.appendingPathComponent("CLAUDE.md"), atomically: true, encoding: .utf8)

        let artifacts = TranscriptLoader.enumerateArtifacts(in: tempDir)
        XCTAssertEqual(artifacts.count, 3)
    }

    func testLoadDictationDayMarkdown() throws {
        try writeFixture(makeDictationDayJSON(), filename: "Dictations_2026-04-07", to: tempDir)

        let day = TranscriptLoader.loadDictationDay(tempDir.appendingPathComponent("Dictations_2026-04-07.md"))
        XCTAssertNotNil(day)
        XCTAssertEqual(day?.entryCount, 2)
        XCTAssertEqual(day?.entries.first?.title, "Morning note")
    }

    func testLoadMalformedDictationMarkdownReturnsNil() throws {
        try "# Dictations with no frontmatter".write(
            to: tempDir.appendingPathComponent("Dictations_2026-04-07.md"),
            atomically: true,
            encoding: .utf8
        )

        let day = TranscriptLoader.loadDictationDay(tempDir.appendingPathComponent("Dictations_2026-04-07.md"))

        XCTAssertNil(day)
    }

    func testEnumerateArtifactsSkipsSymlinkedFiles() throws {
        let outsideDir = makeTempDir()
        defer { removeTempDir(outsideDir) }

        let outsideFile = outsideDir.appendingPathComponent("Call_2026-03-29_10-00-00.md")
        try makeFixtureJSON().write(to: outsideFile, atomically: true, encoding: .utf8)

        let symlinkURL = tempDir.appendingPathComponent("Call_2026-03-29_10-00-00.md")
        try FileManager.default.createSymbolicLink(at: symlinkURL, withDestinationURL: outsideFile)

        let artifacts = TranscriptLoader.enumerateArtifacts(in: tempDir)
        XCTAssertTrue(artifacts.isEmpty)
    }

    func testEnumerateArtifactsAllowsSymlinkedDirectoryRoot() throws {
        let realMeetingsDir = makeTempDir()
        defer { removeTempDir(realMeetingsDir) }

        try writeFixture(makeFixtureJSON(), filename: "Call_2026-03-29_10-00-00", to: realMeetingsDir)

        let symlinkRoot = tempDir.appendingPathComponent("meetings", isDirectory: true)
        try FileManager.default.createSymbolicLink(at: symlinkRoot, withDestinationURL: realMeetingsDir)

        let artifacts = TranscriptLoader.enumerateArtifacts(in: symlinkRoot)
        XCTAssertEqual(artifacts.count, 1)
        XCTAssertEqual(
            artifacts.first?.url.deletingLastPathComponent().standardizedFileURL.path,
            realMeetingsDir.resolvingSymlinksInPath().standardizedFileURL.path
        )
    }

    func testResolveReadableFileRejectsSymlinkEscape() throws {
        let outsideDir = makeTempDir()
        defer { removeTempDir(outsideDir) }

        let outsideFile = outsideDir.appendingPathComponent("Dictations_2026-04-07.md")
        try "# Secret".write(to: outsideFile, atomically: true, encoding: .utf8)

        let symlinkURL = tempDir.appendingPathComponent("Dictations_2026-04-07.md")
        try FileManager.default.createSymbolicLink(at: symlinkURL, withDestinationURL: outsideFile)

        let result = PathSecurity.resolveReadableFile(named: "Dictations_2026-04-07.md", in: tempDir)
        guard case .invalid = result else {
            return XCTFail("Expected symlink escape to be rejected")
        }
    }

    func testResolveReadableFileRejectsParentTraversal() throws {
        let outsideDir = tempDir.appendingPathComponent("outside", isDirectory: true)
        try FileManager.default.createDirectory(at: outsideDir, withIntermediateDirectories: true)
        try "# Secret".write(
            to: outsideDir.appendingPathComponent("Call_secret.md"),
            atomically: true,
            encoding: .utf8
        )

        let result = PathSecurity.resolveReadableFile(named: "../outside/Call_secret.md", in: tempDir)

        guard case .invalid = result else {
            return XCTFail("Expected parent traversal to be rejected")
        }
    }

    func testSpeakerLookup() {
        let fixture = makeFixtureJSON()
        let url = tempDir.appendingPathComponent("Call_lookup.md")
        try! fixture.write(to: url, atomically: true, encoding: .utf8)
        let transcript = TranscriptLoader.load(url)!
        let lookup = TranscriptLoader.speakerLookup(from: transcript)

        XCTAssertEqual(lookup["mic_0"]?.name, "You")
        XCTAssertEqual(lookup["system_0"]?.name, "Jenny Wen")
        XCTAssertEqual(lookup["system_0"]?.persistentId, "80FB272B-6061-4FC4-8408-3F7A974C59DB")
    }
}
