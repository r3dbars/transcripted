import XCTest
@testable import TranscriptedCore

@available(macOS 14.0, *)
final class AudioInitializationTests: XCTestCase {

    func testAudioInitDoesNotEagerlyCreateMicEngine() {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("AudioInitializationTests-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let paths = CoreStoragePaths(
            transcripts: root.appendingPathComponent("captures/meetings", isDirectory: true),
            speakerDB: root.appendingPathComponent("state/speakers.sqlite"),
            statsDB: root.appendingPathComponent("state/stats.sqlite"),
            failedQueue: root.appendingPathComponent("state/failed_transcriptions.json"),
            speakerClips: root.appendingPathComponent("tmp/recordings/speaker_clips", isDirectory: true),
            audioCaptures: root.appendingPathComponent("tmp/recordings", isDirectory: true),
            logs: root.appendingPathComponent("logs", isDirectory: true)
        )

        let audio = Audio(paths: paths)

        XCTAssertNil(audio.engine)
        XCTAssertNil(audio.inputNode)
        XCTAssertNil(audio.systemAudioCapture)
    }
}
