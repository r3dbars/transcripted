import XCTest
@testable import TranscriptedCore

final class RecordingAudioArchiverTests: XCTestCase {
    private var tempRoot: URL!

    override func setUp() {
        super.setUp()
        tempRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent("RecordingAudioArchiverTests-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: tempRoot, withIntermediateDirectories: true)
    }

    override func tearDown() {
        if let tempRoot {
            try? FileManager.default.removeItem(at: tempRoot)
        }
        super.tearDown()
    }

    func testArchiveCopiesLiveMeetingMicAndSystemAudio() throws {
        let scratch = tempRoot.appendingPathComponent("scratch", isDirectory: true)
        let archiveRoot = tempRoot.appendingPathComponent("meetings", isDirectory: true)
        try FileManager.default.createDirectory(at: scratch, withIntermediateDirectories: true)

        let micURL = scratch.appendingPathComponent("meeting_mic.wav")
        let systemURL = scratch.appendingPathComponent("meeting_system.wav")
        let transcriptURL = tempRoot.appendingPathComponent("Call_2026-04-20_10-30-00.md")
        try Data("mic".utf8).write(to: micURL)
        try Data("system".utf8).write(to: systemURL)

        let retained = try RecordingAudioArchiver.archive(
            micURL: micURL,
            systemURL: systemURL,
            transcriptURL: transcriptURL,
            archiveRoot: archiveRoot
        )

        XCTAssertEqual(retained.directory.lastPathComponent, "Call_2026-04-20_10-30-00_audio")
        XCTAssertEqual(retained.micURL?.lastPathComponent, "microphone.wav")
        XCTAssertEqual(retained.systemURL?.lastPathComponent, "system_audio.wav")
        XCTAssertEqual(try Data(contentsOf: retained.micURL!), Data("mic".utf8))
        XCTAssertEqual(try Data(contentsOf: retained.systemURL!), Data("system".utf8))
        XCTAssertTrue(FileManager.default.fileExists(atPath: micURL.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: systemURL.path))
    }

    func testArchiveUsesRecordingNameForImportedAudio() throws {
        let scratch = tempRoot.appendingPathComponent("scratch", isDirectory: true)
        let archiveRoot = tempRoot.appendingPathComponent("meetings", isDirectory: true)
        try FileManager.default.createDirectory(at: scratch, withIntermediateDirectories: true)

        let audioURL = scratch.appendingPathComponent("interview.m4a")
        let transcriptURL = tempRoot.appendingPathComponent("Imported Interview.md")
        try Data("audio".utf8).write(to: audioURL)

        let retained = try RecordingAudioArchiver.archive(
            micURL: nil,
            systemURL: audioURL,
            transcriptURL: transcriptURL,
            archiveRoot: archiveRoot
        )

        XCTAssertNil(retained.micURL)
        XCTAssertEqual(retained.systemURL?.lastPathComponent, "recording.m4a")
        XCTAssertEqual(try Data(contentsOf: retained.systemURL!), Data("audio".utf8))
    }

    func testArchiveKeepsMicOnlyFailedMeetingAudio() throws {
        let scratch = tempRoot.appendingPathComponent("scratch", isDirectory: true)
        let archiveRoot = tempRoot.appendingPathComponent("meetings", isDirectory: true)
        try FileManager.default.createDirectory(at: scratch, withIntermediateDirectories: true)

        let micURL = scratch.appendingPathComponent("meeting_mic.wav")
        let transcriptURL = tempRoot.appendingPathComponent("Failed_2026-04-20_10-30-00.md")
        try Data("mic".utf8).write(to: micURL)

        let retained = try RecordingAudioArchiver.archive(
            micURL: micURL,
            systemURL: nil,
            transcriptURL: transcriptURL,
            archiveRoot: archiveRoot
        )

        XCTAssertEqual(retained.micURL?.lastPathComponent, "microphone.wav")
        XCTAssertNil(retained.systemURL)
        XCTAssertEqual(try Data(contentsOf: retained.micURL!), Data("mic".utf8))
    }

    func testArchiveStillRetainsSystemAudioWhenMicCopyFails() throws {
        let scratch = tempRoot.appendingPathComponent("scratch", isDirectory: true)
        let archiveRoot = tempRoot.appendingPathComponent("meetings", isDirectory: true)
        try FileManager.default.createDirectory(at: scratch, withIntermediateDirectories: true)

        let missingMicURL = scratch.appendingPathComponent("missing-mic.wav")
        let systemURL = scratch.appendingPathComponent("meeting_system.wav")
        let transcriptURL = tempRoot.appendingPathComponent("Partial Meeting.md")
        try Data("system".utf8).write(to: systemURL)

        let retained = try RecordingAudioArchiver.archive(
            micURL: missingMicURL,
            systemURL: systemURL,
            transcriptURL: transcriptURL,
            archiveRoot: archiveRoot
        )

        XCTAssertNil(retained.micURL)
        XCTAssertEqual(retained.systemURL?.lastPathComponent, "system_audio.wav")
        XCTAssertEqual(try Data(contentsOf: retained.systemURL!), Data("system".utf8))
    }

    func testArchiveStillRetainsMicAudioWhenSystemCopyFails() throws {
        let scratch = tempRoot.appendingPathComponent("scratch", isDirectory: true)
        let archiveRoot = tempRoot.appendingPathComponent("meetings", isDirectory: true)
        try FileManager.default.createDirectory(at: scratch, withIntermediateDirectories: true)

        let micURL = scratch.appendingPathComponent("meeting_mic.wav")
        let missingSystemURL = scratch.appendingPathComponent("missing-system.wav")
        let transcriptURL = tempRoot.appendingPathComponent("Partial Meeting.md")
        try Data("mic".utf8).write(to: micURL)

        let retained = try RecordingAudioArchiver.archive(
            micURL: micURL,
            systemURL: missingSystemURL,
            transcriptURL: transcriptURL,
            archiveRoot: archiveRoot
        )

        XCTAssertEqual(retained.micURL?.lastPathComponent, "microphone.wav")
        XCTAssertNil(retained.systemURL)
        XCTAssertEqual(try Data(contentsOf: retained.micURL!), Data("mic".utf8))
    }

    func testArchiveFailsWhenNoProvidedSourceCanBeCopied() {
        let archiveRoot = tempRoot.appendingPathComponent("meetings", isDirectory: true)
        let expectedDirectory = archiveRoot.appendingPathComponent("Missing Meeting_audio", isDirectory: true)

        XCTAssertThrowsError(
            try RecordingAudioArchiver.archive(
                micURL: tempRoot.appendingPathComponent("missing-mic.wav"),
                systemURL: tempRoot.appendingPathComponent("missing-system.wav"),
                transcriptURL: tempRoot.appendingPathComponent("Missing Meeting.md"),
                archiveRoot: archiveRoot
            )
        )
        XCTAssertFalse(
            FileManager.default.fileExists(atPath: expectedDirectory.path),
            "a total copy failure should not leave an empty archive directory"
        )
    }
}
