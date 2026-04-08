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

    func testLoadValidJSON() throws {
        let fixture = makeFixtureJSON()
        try writeFixture(fixture, filename: "Call_test", to: tempDir)

        let transcript = TranscriptLoader.load(tempDir.appendingPathComponent("Call_test.json"))
        XCTAssertNotNil(transcript)
        XCTAssertEqual(transcript?.version, "1.0")
        XCTAssertEqual(transcript?.utterances.count, 2)
        XCTAssertEqual(transcript?.speakers.count, 2)
    }

    func testLoadMalformedJSONReturnsNil() throws {
        try "not json at all".data(using: .utf8)!.write(to: tempDir.appendingPathComponent("Call_bad.json"))
        let transcript = TranscriptLoader.load(tempDir.appendingPathComponent("Call_bad.json"))
        XCTAssertNil(transcript)
    }

    func testLoadMissingFileReturnsNil() {
        let transcript = TranscriptLoader.load(tempDir.appendingPathComponent("Call_missing.json"))
        XCTAssertNil(transcript)
    }

    func testEnumerateSidecars() throws {
        try writeFixture(makeFixtureJSON(), filename: "Call_2026-03-29_10-00-00", to: tempDir)
        try writeFixture(makeFixtureJSON(), filename: "Call_2026-03-30_10-00-00", to: tempDir)
        try writeFixture(makeDictationDayJSON(), filename: "Dictations_2026-04-07", to: tempDir)
        try "other file".data(using: .utf8)!.write(to: tempDir.appendingPathComponent("notes.json"))
        try "not json".data(using: .utf8)!.write(to: tempDir.appendingPathComponent("readme.txt"))

        let sidecars = TranscriptLoader.enumerateSidecars(in: tempDir)
        XCTAssertEqual(sidecars.count, 3)
    }

    func testLoadDictationDayJSON() throws {
        try writeFixture(makeDictationDayJSON(), filename: "Dictations_2026-04-07", to: tempDir)

        let day = TranscriptLoader.loadDictationDay(tempDir.appendingPathComponent("Dictations_2026-04-07.json"))
        XCTAssertNotNil(day)
        XCTAssertEqual(day?.entryCount, 2)
        XCTAssertEqual(day?.entries.first?.title, "Morning note")
    }

    func testSpeakerLookup() {
        let fixture = makeFixtureJSON()
        let transcript = try! JSONDecoder().decode(AgentTranscript.self, from: fixture)
        let lookup = TranscriptLoader.speakerLookup(from: transcript)

        XCTAssertEqual(lookup["mic_0"]?.name, "You")
        XCTAssertEqual(lookup["system_0"]?.name, "Jenny Wen")
        XCTAssertEqual(lookup["system_0"]?.persistentId, "80FB272B-6061-4FC4-8408-3F7A974C59DB")
    }
}
