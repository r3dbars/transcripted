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

    func testMergeStreamsAlreadyTargetFormatSegments() throws {
        let primaryURL = temporaryDirectory.appendingPathComponent("primary-16k.wav")
        let recoveryURL = temporaryDirectory.appendingPathComponent("recovery-16k.wav")

        try writeMonoWAV(
            to: primaryURL,
            sampleRate: 16_000,
            samples: Array(repeating: 0.3, count: 1_600)
        )
        try writeMonoWAV(
            to: recoveryURL,
            sampleRate: 16_000,
            samples: Array(repeating: 0.6, count: 1_600)
        )

        let mergedURL = try XCTUnwrap(
            MicRecordingFileMerger.merge(
                primaryURL: primaryURL,
                segments: [
                    MicRecordingSegment(url: primaryURL),
                    MicRecordingSegment(url: recoveryURL)
                ]
            )
        )

        let merged = try AudioResampler.loadWAV(url: mergedURL)
        XCTAssertEqual(merged.sampleRate, 16_000, accuracy: 0.5)
        XCTAssertEqual(merged.samples.count, 3_200)
        XCTAssertEqual(average(of: merged.samples, range: 200..<1_000), 0.3, accuracy: 0.01)
        XCTAssertEqual(average(of: merged.samples, range: 2_000..<2_800), 0.6, accuracy: 0.01)
    }

    func testMergeManyRecoverySegmentsKeepsEverySegmentInOrder() throws {
        var segments: [MicRecordingSegment] = []
        var urls: [URL] = []

        for index in 0..<6 {
            let url = temporaryDirectory.appendingPathComponent("segment-\(index).wav")
            try writeMonoWAV(
                to: url,
                sampleRate: index.isMultiple(of: 2) ? 48_000 : 44_100,
                samples: Array(repeating: Float(index + 1) / 10.0, count: index.isMultiple(of: 2) ? 4_800 : 4_410)
            )
            urls.append(url)
            segments.append(MicRecordingSegment(
                url: url,
                gapBeforeDuration: index == 0 ? 0 : 0.05
            ))
        }

        let mergedURL = try XCTUnwrap(
            MicRecordingFileMerger.merge(
                primaryURL: urls[0],
                segments: segments
            )
        )

        let merged = try AudioResampler.loadWAV(url: mergedURL)
        XCTAssertEqual(merged.sampleRate, 16_000, accuracy: 0.5)
        XCTAssertLessThanOrEqual(abs(merged.samples.count - 13_600), 384)
        XCTAssertGreaterThan(average(of: merged.samples, range: 200..<900), 0.09)
        XCTAssertLessThan(averageAbsolute(of: merged.samples, range: 1_700..<2_300), 0.001)
        XCTAssertGreaterThan(average(of: merged.samples, range: 12_600..<13_200), 0.55)
        XCTAssertLessThan(average(of: merged.samples, range: 12_600..<13_200), 0.65)

        for url in urls {
            XCTAssertFalse(FileManager.default.fileExists(atPath: url.path))
        }
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
