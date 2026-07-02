import AVFoundation
import XCTest
@testable import TranscriptedCore

@available(macOS 14.0, *)
final class AudioResamplerTests: XCTestCase {

    // MARK: - resample

    func testResampleSameRateIsIdentity() {
        let samples: [Float] = [0.1, 0.2, 0.3, 0.4]
        let out = AudioResampler.resample(samples, from: 16000, to: 16000)
        XCTAssertEqual(out, samples)
    }

    func testResampleEmptyInputReturnsEmpty() {
        let out = AudioResampler.resample([], from: 48000, to: 16000)
        XCTAssertTrue(out.isEmpty)
    }

    func testResample48kTo16kDecimatesByThree() {
        // 48k -> 16k: ratio 3.0. srcIndex = i*3 is integer, so frac is 0 and each
        // output sample is exactly samples[i*3] (pure decimation, no blending).
        let samples: [Float] = (0..<9).map { Float($0) }  // 0,1,...,8
        let out = AudioResampler.resample(samples, from: 48000, to: 16000)

        XCTAssertEqual(out.count, 3)  // floor(9 / 3)
        XCTAssertEqual(out, [0, 3, 6])
    }

    func testResampleInterpolatesAtFractionalSourceIndex() {
        // 24k -> 16k: ratio 1.5. For i=1, srcIndex = 1.5 -> lo=1, hi=2, frac=0.5,
        // so output[1] is the midpoint of samples[1] and samples[2].
        let samples: [Float] = [0, 10, 20, 30, 40, 60]
        let out = AudioResampler.resample(samples, from: 24000, to: 16000)

        XCTAssertEqual(out.count, 4)  // floor(6 / 1.5)
        XCTAssertEqual(out[0], 0, accuracy: 0.000_1)       // srcIndex 0.0
        XCTAssertEqual(out[1], 15, accuracy: 0.000_1)      // 10 + 0.5*(20-10)
        XCTAssertEqual(out[2], 30, accuracy: 0.000_1)      // srcIndex 3.0
        XCTAssertEqual(out[3], 50, accuracy: 0.000_1)      // 40 + 0.5*(60-40)
    }

    func testResampleClampsHighIndexToLastSample() {
        // Upsample 16k -> 24k: ratio 0.666..., the last output index can land on
        // the final source sample where hi clamps to samples.count - 1.
        let samples: [Float] = [1, 2, 3]
        let out = AudioResampler.resample(samples, from: 16000, to: 24000)

        XCTAssertEqual(out.count, 4)  // floor(3 / (16000/24000)) = floor(4.5)
        // Final value must stay within the source range, never read past the end.
        XCTAssertLessThanOrEqual(out.last ?? 0, 3)
        XCTAssertGreaterThanOrEqual(out.last ?? 0, 1)
    }

    func testResampleRejectsUnusableRateAndReturnsInput() {
        // 0 Hz is below the usable floor, so the resampler short-circuits and
        // returns the input untouched.
        let samples: [Float] = [0.5, 0.6]
        let out = AudioResampler.resample(samples, from: 0, to: 16000)
        XCTAssertEqual(out, samples)
    }

    // MARK: - loadAndResample (convertToMono)

    func testLoadAndResampleDownmixesStereoAndResamplesToTargetRate() throws {
        // 1s of constant 48 kHz stereo -> 16 kHz mono through the chunked
        // AVAudioConverter path.
        let url = try writeWAV(sampleRate: 48_000, channels: 2, frames: 48_000, value: 0.5)
        defer { try? FileManager.default.removeItem(at: url) }

        let samples = try AudioResampler.loadAndResample(url: url, targetRate: 16_000)

        // The converter may emit a few frames of slack around 16_000; the
        // destination capacity allows up to +64.
        XCTAssertGreaterThanOrEqual(samples.count, 15_500)
        XCTAssertLessThanOrEqual(samples.count, 16_064)

        // Interior samples should sit at the constant value (edges can carry
        // the anti-aliasing filter's ramp-in).
        let interior = samples[1_000..<15_000]
        let average = interior.reduce(0, +) / Float(interior.count)
        XCTAssertEqual(average, 0.5, accuracy: 0.01)
    }

    func testLoadAndResampleMonoAtTargetRatePassesThrough() throws {
        // Already 16 kHz mono: short-circuits through loadWAV, count is exact.
        let url = try writeWAV(sampleRate: 16_000, channels: 1, frames: 1_600, value: 0.25)
        defer { try? FileManager.default.removeItem(at: url) }

        let samples = try AudioResampler.loadAndResample(url: url, targetRate: 16_000)

        XCTAssertEqual(samples.count, 1_600)
        XCTAssertEqual(samples.first ?? 0, 0.25, accuracy: 0.000_1)
        XCTAssertEqual(samples.last ?? 0, 0.25, accuracy: 0.000_1)
    }

    private func writeWAV(
        sampleRate: Double,
        channels: AVAudioChannelCount,
        frames: AVAudioFrameCount,
        value: Float
    ) throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("AudioResamplerTests-\(UUID().uuidString).wav")
        guard let format = AVAudioFormat(
            commonFormat: .pcmFormatFloat32,
            sampleRate: sampleRate,
            channels: channels,
            interleaved: false
        ), let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frames) else {
            throw NSError(domain: "AudioResamplerTests", code: 1, userInfo: [
                NSLocalizedDescriptionKey: "Failed to create test format or buffer"
            ])
        }

        buffer.frameLength = frames
        for channel in 0..<Int(channels) {
            guard let channelData = buffer.floatChannelData?[channel] else { continue }
            for frame in 0..<Int(frames) {
                channelData[frame] = value
            }
        }

        let file = try AVAudioFile(
            forWriting: url,
            settings: format.settings,
            commonFormat: format.commonFormat,
            interleaved: format.isInterleaved
        )
        try file.write(from: buffer)
        return url
    }

    // MARK: - extractSlice

    // extractSlice guards on AudioRecordingFormatPolicy.isUsableSampleRate, so these use a
    // real 16 kHz rate. Times are derived as (index + 0.5)/rate so Int() truncation lands on
    // the intended sample index regardless of float rounding.
    func testExtractSliceInRange() {
        // 16 kHz: [0..<8]. Slice covering sample indices [4, 6) -> [4, 5].
        let samples: [Float] = (0..<8).map { Float($0) }
        let rate = 16_000.0
        let slice = AudioResampler.extractSlice(from: samples, sampleRate: rate, startTime: 4.5 / rate, endTime: 6.5 / rate)
        XCTAssertEqual(slice, [4, 5])
    }

    func testExtractSliceClampsEndPastBuffer() {
        let samples: [Float] = (0..<8).map { Float($0) }
        let rate = 16_000.0
        // endTime maps to sample 12, clamped to samples.count (8); start at sample 4.
        let slice = AudioResampler.extractSlice(from: samples, sampleRate: rate, startTime: 4.5 / rate, endTime: 12.5 / rate)
        XCTAssertEqual(slice, [4, 5, 6, 7])
    }

    func testExtractSliceClampsNegativeStartToZero() {
        let samples: [Float] = (0..<8).map { Float($0) }
        let rate = 16_000.0
        // Negative startTime clamps to sample 0; endTime maps to sample 2.
        let slice = AudioResampler.extractSlice(from: samples, sampleRate: rate, startTime: -1.0, endTime: 2.5 / rate)
        XCTAssertEqual(slice, [0, 1])
    }

    func testExtractSliceStartGreaterThanOrEqualEndReturnsEmpty() {
        let samples: [Float] = (0..<8).map { Float($0) }
        let rate = 16_000.0
        // In-range indices, but start >= end, so the slice is empty (not the unusable-rate path).
        XCTAssertTrue(AudioResampler.extractSlice(from: samples, sampleRate: rate, startTime: 2.5 / rate, endTime: 2.5 / rate).isEmpty)
        XCTAssertTrue(AudioResampler.extractSlice(from: samples, sampleRate: rate, startTime: 3.5 / rate, endTime: 2.5 / rate).isEmpty)
    }

    func testExtractSliceRejectsUnusableSampleRate() {
        let samples: [Float] = (0..<8).map { Float($0) }
        XCTAssertTrue(AudioResampler.extractSlice(from: samples, sampleRate: 0, startTime: 0, endTime: 1).isEmpty)
    }

    func testExtractSliceRejectsNonFiniteBounds() {
        let samples: [Float] = (0..<8).map { Float($0) }
        let rate = 16_000.0
        XCTAssertTrue(AudioResampler.extractSlice(from: samples, sampleRate: rate, startTime: .nan, endTime: 1).isEmpty)
        XCTAssertTrue(AudioResampler.extractSlice(from: samples, sampleRate: rate, startTime: 0, endTime: .infinity).isEmpty)
    }
}
