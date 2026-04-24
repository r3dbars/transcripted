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
