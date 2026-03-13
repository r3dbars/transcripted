import XCTest
@testable import Transcripted

final class AudioResamplerTests: XCTestCase {

    // MARK: - resample: Identity

    func testResampleSameRateReturnsInput() {
        let input: [Float] = [1.0, 2.0, 3.0, 4.0]
        let result = AudioResampler.resample(input, from: 16000, to: 16000)
        XCTAssertEqual(result, input)
    }

    func testResampleEmptyArrayReturnsEmpty() {
        let result = AudioResampler.resample([], from: 48000, to: 16000)
        XCTAssertTrue(result.isEmpty)
    }

    // MARK: - resample: Downsampling

    func testResampleDownsampleReducesLength() {
        // 48kHz → 16kHz = 3:1 ratio
        let input = [Float](repeating: 1.0, count: 4800)
        let result = AudioResampler.resample(input, from: 48000, to: 16000)
        XCTAssertEqual(result.count, 1600)
    }

    func testResampleDownsamplePreservesConstantSignal() {
        let input = [Float](repeating: 0.5, count: 4800)
        let result = AudioResampler.resample(input, from: 48000, to: 16000)
        for sample in result {
            XCTAssertEqual(sample, 0.5, accuracy: 0.001)
        }
    }

    // MARK: - resample: Upsampling

    func testResampleUpsampleIncreasesLength() {
        let input = [Float](repeating: 1.0, count: 1600)
        let result = AudioResampler.resample(input, from: 16000, to: 48000)
        XCTAssertEqual(result.count, 4800)
    }

    // MARK: - resample: Interpolation correctness

    func testResampleLinearInterpolation() {
        // Simple ramp: [0, 1, 2, 3] at 4Hz → 2Hz should give [0, 2]
        let input: [Float] = [0.0, 1.0, 2.0, 3.0]
        let result = AudioResampler.resample(input, from: 4, to: 2)
        XCTAssertEqual(result.count, 2)
        XCTAssertEqual(result[0], 0.0, accuracy: 0.01)
        XCTAssertEqual(result[1], 2.0, accuracy: 0.01)
    }

    // MARK: - extractSlice: Basic

    func testExtractSliceMiddle() {
        // 1 second of audio at 16kHz
        let samples = [Float](repeating: 1.0, count: 16000)
        let slice = AudioResampler.extractSlice(from: samples, sampleRate: 16000, startTime: 0.25, endTime: 0.75)
        XCTAssertEqual(slice.count, 8000) // 0.5 seconds
    }

    func testExtractSliceFromStart() {
        let samples = [Float](repeating: 1.0, count: 16000)
        let slice = AudioResampler.extractSlice(from: samples, sampleRate: 16000, startTime: 0.0, endTime: 0.5)
        XCTAssertEqual(slice.count, 8000)
    }

    func testExtractSliceToEnd() {
        let samples = [Float](repeating: 1.0, count: 16000)
        let slice = AudioResampler.extractSlice(from: samples, sampleRate: 16000, startTime: 0.5, endTime: 1.0)
        XCTAssertEqual(slice.count, 8000)
    }

    // MARK: - extractSlice: Edge cases

    func testExtractSliceBeyondBounds() {
        let samples = [Float](repeating: 1.0, count: 16000) // 1 second
        let slice = AudioResampler.extractSlice(from: samples, sampleRate: 16000, startTime: 0.5, endTime: 2.0)
        // Should clamp to end of array
        XCTAssertEqual(slice.count, 8000)
    }

    func testExtractSliceNegativeStart() {
        let samples = [Float](repeating: 1.0, count: 16000)
        let slice = AudioResampler.extractSlice(from: samples, sampleRate: 16000, startTime: -1.0, endTime: 0.5)
        XCTAssertEqual(slice.count, 8000)
    }

    func testExtractSliceStartAfterEnd() {
        let samples = [Float](repeating: 1.0, count: 16000)
        let slice = AudioResampler.extractSlice(from: samples, sampleRate: 16000, startTime: 0.8, endTime: 0.2)
        XCTAssertTrue(slice.isEmpty)
    }

    func testExtractSliceEmptyArray() {
        let slice = AudioResampler.extractSlice(from: [], sampleRate: 16000, startTime: 0.0, endTime: 1.0)
        XCTAssertTrue(slice.isEmpty)
    }
}
