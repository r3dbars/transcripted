import XCTest
@preconcurrency import AVFoundation
@testable import TranscriptedCore

@available(macOS 14.0, *)
final class AudioDiagnosticsSnapshotTests: XCTestCase {

    private func makeAudio() -> Audio {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("AudioDiagnosticsSnapshotTests-\(UUID().uuidString)", isDirectory: true)
        let paths = CoreStoragePaths(
            transcripts: root.appendingPathComponent("captures/meetings", isDirectory: true),
            speakerDB: root.appendingPathComponent("state/speakers.sqlite"),
            statsDB: root.appendingPathComponent("state/stats.sqlite"),
            failedQueue: root.appendingPathComponent("state/failed_transcriptions.json"),
            speakerClips: root.appendingPathComponent("tmp/recordings/speaker_clips", isDirectory: true),
            audioCaptures: root.appendingPathComponent("tmp/recordings", isDirectory: true),
            logs: root.appendingPathComponent("logs", isDirectory: true)
        )
        return Audio(paths: paths)
    }

    func testSnapshotIncludesIssue500SignalDiagnostics() {
        let audio = makeAudio()
        audio.prepareForNewRecordingStart()

        audio.recordMicSignalPeaks(raw: 0.03, processed: 0.36)
        audio.recordSystemSignalPeak(0.25)

        let snapshot = audio.createPipelineDiagnosticsSnapshot()

        XCTAssertEqual(snapshot.micRawPeak, "0.03000")
        XCTAssertEqual(snapshot.micProcessedPeak, "0.36000")
        XCTAssertEqual(snapshot.systemAudioPeak, "0.25000")
        XCTAssertEqual(snapshot.privacySafeContext["mic_raw_peak"], "0.03000")
        XCTAssertEqual(snapshot.privacySafeContext["mic_processed_peak"], "0.36000")
        XCTAssertEqual(snapshot.privacySafeContext["system_peak"], "0.25000")
    }

    func testSnapshotResetsSignalDiagnosticsForNewRecording() {
        let audio = makeAudio()
        audio.recordMicSignalPeaks(raw: 0.03, processed: 0.36)
        audio.recordSystemSignalPeak(0.25)

        audio.prepareForNewRecordingStart()

        let snapshot = audio.createPipelineDiagnosticsSnapshot()

        XCTAssertEqual(snapshot.micRawPeak, "0.00000")
        XCTAssertEqual(snapshot.micProcessedPeak, "0.00000")
        XCTAssertEqual(snapshot.systemAudioPeak, "0.00000")
    }

    func testRouteVolumeDiagnosticsExposeBeforeAndAfterKeys() {
        let audio = makeAudio()
        audio.prepareForNewRecordingStart()

        let context = audio.createRouteVolumeDiagnosticsContext(currentPhase: "after")

        XCTAssertNotNil(context["default_input_volume_before"])
        XCTAssertNotNil(context["default_output_volume_before"])
        XCTAssertNotNil(context["default_system_output_volume_before"])
        XCTAssertNotNil(context["default_input_volume_after"])
        XCTAssertNotNil(context["default_output_volume_after"])
        XCTAssertNotNil(context["default_system_output_volume_after"])
    }

    func testNormalizedSystemLevelUsesAllChannels() throws {
        let audio = makeAudio()
        let buffer = try makeStereoBuffer(left: 0, right: 0.5)

        let level = audio.normalizedRMSLevel(buffer: buffer)

        XCTAssertGreaterThan(level, 0.8)
    }

    private func makeStereoBuffer(left: Float, right: Float) throws -> AVAudioPCMBuffer {
        let frameCount = 512
        let format = try XCTUnwrap(AVAudioFormat(
            commonFormat: .pcmFormatFloat32,
            sampleRate: 48_000,
            channels: 2,
            interleaved: false
        ))
        let buffer = try XCTUnwrap(AVAudioPCMBuffer(
            pcmFormat: format,
            frameCapacity: AVAudioFrameCount(frameCount)
        ))
        buffer.frameLength = AVAudioFrameCount(frameCount)

        guard let channelData = buffer.floatChannelData else {
            XCTFail("Missing channel data")
            return buffer
        }

        for index in 0..<frameCount {
            channelData[0][index] = left
            channelData[1][index] = right
        }
        return buffer
    }
}
