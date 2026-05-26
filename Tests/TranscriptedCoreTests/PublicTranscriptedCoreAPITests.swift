import XCTest
import TranscriptedCore

@available(macOS 14.0, *)
final class PublicTranscriptedCoreAPITests: XCTestCase {

    func testPublicCoreStoragePathsAndRecordingValidatorAreImportable() {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("PublicTranscriptedCoreAPITests-\(UUID().uuidString)", isDirectory: true)
        let paths = CoreStoragePaths(
            transcripts: root.appendingPathComponent("meetings", isDirectory: true),
            speakerDB: root.appendingPathComponent("speakers.sqlite"),
            statsDB: root.appendingPathComponent("stats.sqlite"),
            failedQueue: root.appendingPathComponent("failed.json"),
            speakerClips: root.appendingPathComponent("clips", isDirectory: true),
            audioCaptures: root.appendingPathComponent("recordings", isDirectory: true),
            logs: root.appendingPathComponent("logs", isDirectory: true)
        )

        XCTAssertEqual(paths.transcripts.lastPathComponent, "meetings")
        XCTAssertEqual(RecordingValidator.minimumDiskSpace, 100 * 1024 * 1024)
        XCTAssertTrue(RecordingValidator.validateSavePath(paths.transcripts).isValid)
    }
}
