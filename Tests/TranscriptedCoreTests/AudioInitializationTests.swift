import XCTest
@preconcurrency import AVFoundation
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

    func testAudioRecordingFormatPolicyRejectsInvalidSampleRatesBeforeCreatingFormats() throws {
        for sampleRate in [0, -1, Double.nan, Double.infinity, -Double.infinity, 7_999, 384_001] {
            XCTAssertFalse(
                AudioRecordingFormatPolicy.isUsableSampleRate(sampleRate),
                "sample rate \(sampleRate) should not be accepted for CoreAudio format creation"
            )
            XCTAssertThrowsError(
                try AudioRecordingFormatPolicy.makeMonoOutputFormat(sampleRate: sampleRate),
                "invalid sample rates must throw before AVAudioFormat is asked to build a format"
            )
        }

        let monoFormat = try AudioRecordingFormatPolicy.makeMonoOutputFormat(sampleRate: 48_000)
        XCTAssertEqual(monoFormat.sampleRate, 48_000, accuracy: 0.1)
        XCTAssertEqual(monoFormat.channelCount, 1)
    }

    func testAudioRecordingFormatPolicySnapshotsOnlyUsableFormats() throws {
        let format = try XCTUnwrap(AVAudioFormat(
            commonFormat: .pcmFormatFloat32,
            sampleRate: 48_000,
            channels: 2,
            interleaved: false
        ))

        let snapshot = try XCTUnwrap(AudioRecordingFormatPolicy.snapshot(format))

        XCTAssertEqual(snapshot.sampleRate, 48_000, accuracy: 0.1)
        XCTAssertEqual(snapshot.channelCount, 2)
    }

    func testStopOnIdleAudioDoesNotCrashAndBumpsGeneration() {
        // The stop refactor moves engine teardown to a background queue.
        // On a fresh Audio with no engine, stop() should still:
        //   - synchronously bump the recordingSessionGeneration so any
        //     concurrent recovery work observes the new boundary
        //   - return immediately to the caller
        //   - not crash on the missing engine reference
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
        let initialGeneration = audio.recordingSessionGeneration

        audio.stop()

        XCTAssertEqual(
            audio.recordingSessionGeneration,
            initialGeneration &+ 1,
            "stop() must synchronously bump the recording session generation so concurrent recovery work invalidates correctly"
        )
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
