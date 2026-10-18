import AVFoundation
import XCTest
@testable import TranscriptedCore

@available(macOS 14.0, *)
final class AudioRepeatStopTests: XCTestCase {
    /// Core stops a recovered recording itself (disk full, write failure) and
    /// the host's stop lands before the main-thread isRecording reset. The
    /// repeat stop must join the first one, so the merged mic file survives.
    func testRepeatStopJoinsTheInFlightStopAndKeepsTheMergedMic() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("AudioRepeatStopTests-\(UUID().uuidString)", isDirectory: true)
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
        try FileManager.default.createDirectory(at: paths.audioCaptures, withIntermediateDirectories: true)

        let audio = Audio(paths: paths)
        audio.prepareForNewRecordingStart()
        let primaryURL = paths.audioCaptures.appendingPathComponent("mic.wav")
        let recoveryURL = paths.audioCaptures.appendingPathComponent("mic-recovery.wav")
        try writeMonoWAV(to: primaryURL)
        try writeMonoWAV(to: recoveryURL)
        audio.originalMicAudioFileURL = primaryURL
        audio.micAudioFileURL = recoveryURL
        audio.micSegments = [
            MicRecordingSegment(url: primaryURL),
            MicRecordingSegment(url: recoveryURL, gapBeforeDuration: 0.1)
        ]

        var completions: [(generation: UInt64, micURL: URL?)] = []
        let completed = expectation(description: "stop completed")
        audio.onRecordingCompleteWithGeneration = { generation, micURL, _, _ in
            completions.append((generation, micURL))
            completed.fulfill()
        }

        let firstStopGeneration = audio.predictedNextRecordingSessionGeneration()
        audio.stop()
        XCTAssertEqual(audio.inFlightStopGeneration, firstStopGeneration)
        audio.stop()
        XCTAssertEqual(
            audio.recordingSessionGeneration,
            firstStopGeneration,
            "the repeat stop must not open a second finalization"
        )

        wait(for: [completed], timeout: 5.0)
        XCTAssertEqual(completions.count, 1)
        XCTAssertEqual(completions.first?.generation, firstStopGeneration)
        let micURL = try XCTUnwrap(completions.first?.micURL)
        XCTAssertEqual(micURL.lastPathComponent, "mic_merged.wav")
        XCTAssertTrue(FileManager.default.fileExists(atPath: micURL.path))
        XCTAssertEqual(audio.micAudioFileURL, micURL)
        XCTAssertNil(audio.inFlightStopGeneration)
    }

    /// A start made while the last stop is still finalizing is in preflight
    /// with no generation of its own. A stop then (the bridge's start
    /// timeout) must still cancel it, or it would open the mic unowned later.
    func testStopDuringInFlightStopCancelsAPendingStart() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("AudioRepeatStopTests-\(UUID().uuidString)", isDirectory: true)
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
        try FileManager.default.createDirectory(at: paths.audioCaptures, withIntermediateDirectories: true)

        let audio = Audio(paths: paths)
        audio.prepareForNewRecordingStart()
        let completed = expectation(description: "stop completed")
        audio.onRecordingCompleteWithGeneration = { _, _, _, _ in completed.fulfill() }

        audio.stop()
        XCTAssertNotNil(audio.inFlightStopGeneration)
        audio.start()
        XCTAssertTrue(audio.isStarting)
        audio.stop()
        XCTAssertFalse(audio.isStarting, "the stop must drop the start still in preflight")

        wait(for: [completed], timeout: 5.0)
        XCTAssertFalse(audio.isStarting)
        XCTAssertFalse(audio.isRecording)
    }

    private func writeMonoWAV(to url: URL) throws {
        let format = try XCTUnwrap(AVAudioFormat(
            commonFormat: .pcmFormatFloat32,
            sampleRate: 16_000,
            channels: 1,
            interleaved: false
        ))
        let file = try AVAudioFile(
            forWriting: url,
            settings: format.settings,
            commonFormat: format.commonFormat,
            interleaved: format.isInterleaved
        )
        let buffer = try XCTUnwrap(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 1_600))
        buffer.frameLength = 1_600
        let channel = try XCTUnwrap(buffer.floatChannelData?[0])
        for index in 0..<1_600 {
            channel[index] = 0.5
        }
        try file.write(from: buffer)
    }
}
