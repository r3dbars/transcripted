import XCTest
@testable import transcripted_qa

final class GenerateFixturesTests: XCTestCase {
    private var tempRoot: URL!

    override func setUpWithError() throws {
        tempRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent("GenerateFixturesTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tempRoot, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        if let tempRoot {
            try? FileManager.default.removeItem(at: tempRoot)
        }
    }

    func testGenerateFixturesRefusesToDeleteAFolderItDidNotMake() throws {
        let keep = tempRoot.appendingPathComponent("meeting.md")
        try "keep me".write(to: keep, atomically: true, encoding: .utf8)

        let command = try GenerateFixtures.parse(["--output", tempRoot.path])
        XCTAssertThrowsError(try command.run())

        XCTAssertEqual(try String(contentsOf: keep, encoding: .utf8), "keep me")
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: tempRoot.path), ["meeting.md"])
    }

    func testGenerateFixturesReplacesItsOwnPreviousRun() throws {
        let output = tempRoot.appendingPathComponent("fixtures")
        try GenerateFixtures.parse(["--output", output.path]).run()
        let stale = output.appendingPathComponent("stale.txt")
        try "old".write(to: stale, atomically: true, encoding: .utf8)

        try GenerateFixtures.parse(["--output", output.path]).run()

        XCTAssertFalse(FileManager.default.fileExists(atPath: stale.path))
        XCTAssertTrue(FileManager.default.fileExists(
            atPath: output.appendingPathComponent(GenerateFixtures.markerName).path))
    }
}
