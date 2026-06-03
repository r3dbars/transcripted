import XCTest
@preconcurrency import AVFoundation
import CoreAudio
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
        // Issue #500: the captured-device input scalar is always reported (even
        // as "unavailable" when the device exposes no readable scalar) so the
        // scalar-drop sub-mechanism stays detectable on the device we actually
        // record from, not just the system default input.
        XCTAssertNotNil(snapshot.privacySafeContext["captured_input_volume_before"])
        XCTAssertNotNil(snapshot.privacySafeContext["captured_input_volume_during"])
    }

    func testHandleMicBufferAppliesAGCBeforeMicCallbackAndDiagnostics() throws {
        let audio = makeAudio()
        audio.prepareForNewRecordingStart()
        audio.realtimeAGC = RealtimeAGC()
        defer {
            audio.onMicPCMBuffer = nil
            audio.realtimeAGC = nil
        }

        var callbackPeaks: [Float] = []
        audio.onMicPCMBuffer = { buffer in
            callbackPeaks.append(audio.linearPeak(buffer: buffer))
        }

        let rawPeak: Float = 0.04
        for _ in 0..<40 {
            let buffer = try makeMonoSineBuffer(peak: rawPeak)
            let originalPeak = audio.linearPeak(buffer: buffer)
            audio.handleMicBuffer(buffer)

            XCTAssertEqual(
                audio.linearPeak(buffer: buffer),
                originalPeak,
                accuracy: 0.0001,
                "handleMicBuffer must leave the CoreAudio-owned input buffer untouched"
            )
        }

        let processedPeak = try XCTUnwrap(callbackPeaks.last)
        XCTAssertGreaterThan(processedPeak, 0.40, "mic callback should receive the AGC-processed copy")
        XCTAssertLessThan(processedPeak, 0.55, "mic callback should stay near the AGC target and avoid clipping")

        let snapshot = audio.createPipelineDiagnosticsSnapshot()
        XCTAssertEqual(snapshot.micRawPeak, "0.04000")
        XCTAssertGreaterThan(
            Double(snapshot.micProcessedPeak) ?? 0,
            Double(snapshot.micRawPeak) ?? 1,
            "diagnostics should prove the processed meeting mic path is louder than the raw input"
        )
        XCTAssertEqual(snapshot.privacySafeContext["realtime_agc"], "true")
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

    func testCapturedInputBaselineRequiresSameDevice() {
        let audio = makeAudio()
        let originalInput = AudioDeviceID(42)
        let replacementInput = AudioDeviceID(43)

        audio.recordRecordingStartCapturedInput(deviceID: originalInput)

        XCTAssertEqual(audio.recordingStartCapturedInputDeviceID, originalInput)
        XCTAssertEqual(audio.recordingStartCapturedInputVolume(matching: replacementInput), "unavailable")

        audio.resetRecordingStartCapturedInput()

        XCTAssertNil(audio.recordingStartCapturedInputDeviceID)
        XCTAssertEqual(audio.recordingStartCapturedInputVolume(matching: originalInput), "unavailable")
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

    private func makeMonoSineBuffer(peak: Float, frames: Int = 4096) throws -> AVAudioPCMBuffer {
        let format = try XCTUnwrap(AVAudioFormat(
            commonFormat: .pcmFormatFloat32,
            sampleRate: 48_000,
            channels: 1,
            interleaved: false
        ))
        let buffer = try XCTUnwrap(AVAudioPCMBuffer(
            pcmFormat: format,
            frameCapacity: AVAudioFrameCount(frames)
        ))
        buffer.frameLength = AVAudioFrameCount(frames)

        guard let channelData = buffer.floatChannelData?[0] else {
            XCTFail("Missing channel data")
            return buffer
        }

        let twoPiF = 2.0 * Double.pi * 1_000.0
        for index in 0..<frames {
            let t = Double(index) / 48_000.0
            channelData[index] = peak * Float(sin(twoPiF * t))
        }
        return buffer
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
