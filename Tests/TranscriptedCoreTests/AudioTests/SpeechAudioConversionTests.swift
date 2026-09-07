import AVFoundation
import XCTest
@testable import TranscriptedCore

final class SpeechAudioConversionTests: XCTestCase {
    func testMicrophoneDownmixPreservesSpeechAcrossChannelLayouts() throws {
        for interleaved in [false, true] {
            for channels: [[Float]] in [
                [[0.25, -0.5, 0.75]],
                [[0.25, -0.5, 0.75], [0, 0, 0]],
                [[0, 0, 0], [0.25, -0.5, 0.75]],
                [[0.25, -0.5, 0.75], [-0.25, 0.5, -0.75]]
            ] {
                let format = try XCTUnwrap(AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 48000, channels: AVAudioChannelCount(channels.count), interleaved: interleaved))
                let buffer = try XCTUnwrap(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 3))
                buffer.frameLength = 3
                let data = try XCTUnwrap(buffer.floatChannelData)
                for channel in channels.indices {
                    for frame in 0..<3 {
                        if interleaved { data[0][frame * channels.count + channel] = channels[channel][frame] }
                        else { data[channel][frame] = channels[channel][frame] }
                    }
                }
                XCTAssertEqual(MicrophoneDownmix.monoSamples(from: buffer), [0.25, -0.5, 0.75])
            }
        }
    }

    func testMicrophoneDownmixHandlesEmptyAndUnsupportedPCM() throws {
        let format = try XCTUnwrap(AVAudioFormat(commonFormat: .pcmFormatInt16, sampleRate: 48000, channels: 1, interleaved: false))
        let buffer = try XCTUnwrap(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 8))
        XCTAssertEqual(MicrophoneDownmix.monoSamples(from: buffer), [])
        buffer.frameLength = 8
        XCTAssertNil(MicrophoneDownmix.monoSamples(from: buffer))
    }

    func testSpeechResamplerRejectsAliasesAndPreservesPassband() throws {
        for rate in [24000.0, 44100.0, 48000.0] {
            let low = tone(frequency: 1000, rate: rate, seconds: 1)
            let high = tone(frequency: 10000, rate: rate, seconds: 1)
            let passband = try AudioResampler.resampleForSpeech(low, from: rate)
            let stopband = try AudioResampler.resampleForSpeech(high, from: rate)
            XCTAssertEqual(passband.count, 16000, accuracy: 1)
            XCTAssertEqual(rms(passband), sqrt(0.5), accuracy: 0.02)
            XCTAssertLessThan(rms(stopband), 0.01, "alias rejection at \(rate)")
        }
    }

    func testSpeechResamplerPreservesIdentityEmptyAndShortDurations() throws {
        XCTAssertEqual(try AudioResampler.resampleForSpeech([0.25, -0.5], from: 16000), [0.25, -0.5])
        XCTAssertEqual(try AudioResampler.resampleForSpeech([], from: 48000), [])
        for count in [3, 48, 480, 4801] {
            let output = try AudioResampler.resampleForSpeech(Array(repeating: Float(0.5), count: count), from: 48000)
            XCTAssertEqual(output.count, count / 3, accuracy: 1)
            XCTAssertTrue(output.allSatisfy(\.isFinite))
        }
        XCTAssertThrowsError(try AudioResampler.resampleForSpeech([1], from: 0))
        XCTAssertThrowsError(try AudioResampler.resampleForSpeech([1], from: .nan))
    }

    func testRateSegmentsKeepBothDurationsAndTrailingSignal() throws {
        var combined: [Float] = []
        for rate in [24000.0, 48000.0] {
            combined += try AudioResampler.resampleForSpeech(tone(frequency: 1000, rate: rate, seconds: 0.1), from: rate)
        }
        XCTAssertEqual(combined.count, 3200, accuracy: 2)
        XCTAssertGreaterThan(rms(Array(combined.suffix(800))), 0.65)
    }

    private func tone(frequency: Double, rate: Double, seconds: Double) -> [Float] {
        (0..<Int(rate * seconds)).map { Float(sin(2 * Double.pi * frequency * Double($0) / rate)) }
    }
    private func rms(_ samples: [Float]) -> Double {
        let interior = samples.dropFirst(min(100, samples.count / 4)).dropLast(min(100, samples.count / 4))
        return sqrt(interior.reduce(0.0) { $0 + Double($1) * Double($1) } / Double(interior.count))
    }
}
