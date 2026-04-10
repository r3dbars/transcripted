import AVFoundation
import XCTest
@testable import TranscriptedCore

@available(macOS 14.0, *)
final class MicRecordingFileMergerTests: XCTestCase {
    private var temporaryDirectory: URL!

    override func setUp() {
        super.setUp()
        temporaryDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("MicRecordingFileMergerTests-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: temporaryDirectory, withIntermediateDirectories: true)
    }

    override func tearDown() {
        if let temporaryDirectory {
            try? FileManager.default.removeItem(at: temporaryDirectory)
        }
        temporaryDirectory = nil
        super.tearDown()
    }

    func testMergePadsRecoveryGapAndResamplesSegments() throws {
        let primaryURL = temporaryDirectory.appendingPathComponent("primary.wav")
        let recoveryURL = temporaryDirectory.appendingPathComponent("recovery.wav")

        try writeMonoWAV(
            to: primaryURL,
            sampleRate: 48_000,
            samples: Array(repeating: 0.8, count: 12_000)
        )
        try writeMonoWAV(
            to: recoveryURL,
            sampleRate: 44_100,
            samples: Array(repeating: 0.2, count: 11_025)
        )

        let mergedURL = try XCTUnwrap(
            MicRecordingFileMerger.merge(
                primaryURL: primaryURL,
                segments: [
                    MicRecordingSegment(url: primaryURL),
                    MicRecordingSegment(url: recoveryURL, gapBeforeDuration: 0.15)
                ]
            )
        )

        XCTAssertTrue(FileManager.default.fileExists(atPath: mergedURL.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: primaryURL.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: recoveryURL.path))

        let merged = try AudioResampler.loadWAV(url: mergedURL)
        XCTAssertEqual(merged.sampleRate, 16_000, accuracy: 0.5)
        XCTAssertLessThanOrEqual(abs(merged.samples.count - 10_400), 64)

        XCTAssertGreaterThan(average(of: merged.samples, range: 200..<1_000), 0.75)
        XCTAssertLessThan(averageAbsolute(of: merged.samples, range: 4_300..<6_100), 0.001)
        XCTAssertGreaterThan(average(of: merged.samples, range: 6_800..<7_600), 0.18)
        XCTAssertLessThan(average(of: merged.samples, range: 6_800..<7_600), 0.22)
    }

    func testSingleSegmentReturnsPrimaryWithoutRewriting() throws {
        let primaryURL = temporaryDirectory.appendingPathComponent("primary.wav")
        try writeMonoWAV(
            to: primaryURL,
            sampleRate: 48_000,
            samples: Array(repeating: 0.5, count: 4_800)
        )

        let resolvedURL = try XCTUnwrap(
            MicRecordingFileMerger.merge(
                primaryURL: primaryURL,
                segments: [MicRecordingSegment(url: primaryURL)]
            )
        )

        XCTAssertEqual(resolvedURL, primaryURL)
        XCTAssertTrue(FileManager.default.fileExists(atPath: primaryURL.path))
    }

    private func writeMonoWAV(to url: URL, sampleRate: Double, samples: [Float]) throws {
        guard let format = AVAudioFormat(
            commonFormat: .pcmFormatFloat32,
            sampleRate: sampleRate,
            channels: 1,
            interleaved: false
        ) else {
            XCTFail("Failed to create test format")
            return
        }

        let file = try AVAudioFile(
            forWriting: url,
            settings: format.settings,
            commonFormat: format.commonFormat,
            interleaved: format.isInterleaved
        )
        guard let buffer = AVAudioPCMBuffer(
            pcmFormat: format,
            frameCapacity: AVAudioFrameCount(samples.count)
        ) else {
            XCTFail("Failed to create test buffer")
            return
        }

        buffer.frameLength = AVAudioFrameCount(samples.count)
        guard let channelData = buffer.floatChannelData?[0] else {
            XCTFail("Missing channel data")
            return
        }
        samples.withUnsafeBufferPointer { pointer in
            guard let baseAddress = pointer.baseAddress else { return }
            channelData.update(from: baseAddress, count: samples.count)
        }
        try file.write(from: buffer)
    }

    private func average(of samples: [Float], range: Range<Int>) -> Float {
        let slice = Array(samples[range])
        guard !slice.isEmpty else { return 0 }
        return slice.reduce(0, +) / Float(slice.count)
    }

    private func averageAbsolute(of samples: [Float], range: Range<Int>) -> Float {
        let slice = Array(samples[range])
        guard !slice.isEmpty else { return 0 }
        return slice.reduce(0) { $0 + abs($1) } / Float(slice.count)
    }
}
