import AVFoundation
import Foundation
import XCTest
@testable import transcripted_cli

final class TranscribeMediaLoaderTests: XCTestCase {
    func testStereoDecodeKeepsSignalFromEitherChannel() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        var powers: [Double] = []
        for activeChannel in 0..<2 {
            let url = root.appendingPathComponent("channel-\(activeChannel).wav")
            try writeTone(to: url, sampleRate: 48_000, channels: 2, activeChannel: activeChannel)
            let decoded = try await TranscribeMediaLoader.loadSamples(from: url)
            XCTAssertGreaterThan(decoded.samples.count, 400)
            let interior = decoded.samples.dropFirst(100).dropLast(100)
            let power = interior.reduce(0.0) { $0 + Double($1 * $1) } / Double(max(1, interior.count))
            XCTAssertGreaterThan(power, 0.01, "A voice present only in channel \(activeChannel) must survive mono decode")
            powers.append(power)
        }
        XCTAssertEqual(powers[0], powers[1], accuracy: 0.001, "Left-only and right-only recordings must receive the same gain")
    }

    func testMonoDecodeKeepsExistingSamples() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let url = root.appendingPathComponent("mono.wav")
        let expected = try writeTone(to: url, sampleRate: 16_000, channels: 1, activeChannel: 0)
        let decoded = try await TranscribeMediaLoader.loadSamples(from: url)
        XCTAssertEqual(decoded.samples, expected)
    }

    @discardableResult
    private func writeTone(to url: URL, sampleRate: Double, channels: AVAudioChannelCount, activeChannel: Int) throws -> [Float] {
        let format = try XCTUnwrap(AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: sampleRate, channels: channels, interleaved: false))
        let count = AVAudioFrameCount(sampleRate / 10)
        let buffer = try XCTUnwrap(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: count))
        buffer.frameLength = count
        let data = try XCTUnwrap(buffer.floatChannelData)
        let tone = (0..<Int(count)).map { Float(0.5 * sin(2 * .pi * 400 * Double($0) / sampleRate)) }
        for channel in 0..<Int(channels) {
            for index in tone.indices { data[channel][index] = channel == activeChannel ? tone[index] : 0 }
        }
        var settings = format.settings
        settings.removeValue(forKey: AVLinearPCMIsNonInterleaved)
        let file = try AVAudioFile(forWriting: url, settings: settings)
        try file.write(from: buffer)
        return tone
    }
}
