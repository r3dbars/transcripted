import XCTest
@testable import TranscriptedCore

final class SystemAudioBackendSelectionTests: XCTestCase {
    func testDefaultFactoryCreatesCoreAudioWithoutAcquiringPermission() {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let paths = CoreStoragePaths(
            transcripts: root.appendingPathComponent("transcripts"),
            speakerDB: root.appendingPathComponent("speakers.sqlite"),
            statsDB: root.appendingPathComponent("stats.sqlite"),
            failedQueue: root.appendingPathComponent("failed.json"),
            speakerClips: root.appendingPathComponent("clips"),
            audioCaptures: root.appendingPathComponent("audio"),
            logs: root.appendingPathComponent("logs")
        )
        defer { try? FileManager.default.removeItem(at: root) }
        let audio = Audio(paths: paths)
        XCTAssertNil(audio.systemAudioCapture)
        let capture = audio.makeSystemAudioCaptureForRecordingAttempt()
        XCTAssertTrue(capture is CoreAudioSystemAudioCapture)
        XCTAssertEqual(capture?.diagnosticBackendName, "core_audio_tap")
        XCTAssertNil(capture?.audioFormat, "Factory creation must not prepare a HAL tap or acquire permission")
        XCTAssertNil(audio.engine, "Factory selection must not acquire microphone access")
    }
}
