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
}
