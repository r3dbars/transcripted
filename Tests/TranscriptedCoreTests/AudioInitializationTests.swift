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

    func testAudioDefaultsVoiceProcessingOff() {
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

        // Default off: existing users on v1.1.24 (where VPIO was
        // unconditionally on) should land on the no-Zoom-ducking path
        // after upgrade unless they explicitly opt in via Settings.
        XCTAssertFalse(audio.enableVoiceProcessing,
                       "enableVoiceProcessing must default to false to avoid the system-wide ducking regression")
    }

    func testPrepareForNewRecordingStartClearsStaleCaptureArtifacts() {
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
        audio.originalMicAudioFileURL = root.appendingPathComponent("stale-mic.wav")
        audio.micAudioFileURL = root.appendingPathComponent("stale-mic.wav")
        audio.systemAudioFileURL = root.appendingPathComponent("stale-system.wav")
        audio.systemAudioFailed = true
        audio.appendMicSegment(MicRecordingSegment(url: root.appendingPathComponent("stale-segment.wav")))

        audio.prepareForNewRecordingStart()

        XCTAssertNil(audio.originalMicAudioFileURL)
        XCTAssertNil(audio.micAudioFileURL)
        XCTAssertNil(audio.systemAudioFileURL)
        XCTAssertFalse(audio.systemAudioFailed)
        XCTAssertTrue(audio.micSegments.isEmpty)
    }
}
