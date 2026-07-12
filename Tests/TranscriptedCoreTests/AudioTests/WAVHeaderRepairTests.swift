import AVFoundation
import XCTest
@testable import TranscriptedCore

final class WAVHeaderRepairTests: XCTestCase {
    private var temporaryDirectory: URL!

    override func setUp() {
        super.setUp()
        temporaryDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("WAVHeaderRepairTests-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: temporaryDirectory, withIntermediateDirectories: true)
    }

    override func tearDown() {
        if let temporaryDirectory {
            try? FileManager.default.removeItem(at: temporaryDirectory)
        }
        temporaryDirectory = nil
        super.tearDown()
    }

    func testFinalizedFileNeedsNoRepair() throws {
        let url = temporaryDirectory.appendingPathComponent("clean.wav")
        try writeMonoWAV(to: url, sampleRate: 48_000, samples: Array(repeating: 0.5, count: 9_600))

        XCTAssertFalse(try WAVHeaderRepair.repairIfNeeded(at: url))

        let file = try AVAudioFile(forReading: url)
        XCTAssertEqual(file.length, 9_600)
    }

    func testRepairsCrashOrphanedHeaderAndRecoversAudio() throws {
        let url = temporaryDirectory.appendingPathComponent("orphaned.wav")
        try writeMonoWAV(to: url, sampleRate: 48_000, samples: Array(repeating: 0.5, count: 9_600))

        // Simulate a writer killed before finalizing: zero the RIFF and data
        // size fields the way an unflushed AVAudioFile header looks on disk.
        try zeroHeaderSizes(at: url)
        let unreadable = try AVAudioFile(forReading: url)
        XCTAssertEqual(unreadable.length, 0, "zeroed header must read as empty to model the crash state")

        XCTAssertTrue(try WAVHeaderRepair.repairIfNeeded(at: url))

        let repaired = try AVAudioFile(forReading: url)
        XCTAssertEqual(repaired.length, 9_600)

        let buffer = try XCTUnwrap(AVAudioPCMBuffer(
            pcmFormat: repaired.processingFormat,
            frameCapacity: 9_600
        ))
        try repaired.read(into: buffer)
        XCTAssertEqual(buffer.frameLength, 9_600)
        let samples = try XCTUnwrap(buffer.floatChannelData?[0])
        XCTAssertEqual(samples[4_000], 0.5, accuracy: 0.001)

        // Idempotent: a second pass finds nothing to do.
        XCTAssertFalse(try WAVHeaderRepair.repairIfNeeded(at: url))
    }

    func testRepairsTruncatedFileByShrinkingDeclaredSize() throws {
        let url = temporaryDirectory.appendingPathComponent("truncated.wav")
        try writeMonoWAV(to: url, sampleRate: 48_000, samples: Array(repeating: 0.5, count: 9_600))

        // Chop the tail off so the declared data size exceeds the bytes on disk.
        let handle = try FileHandle(forUpdating: url)
        let originalSize = try handle.seekToEnd()
        try handle.truncate(atOffset: originalSize - 8_000)
        try handle.close()

        XCTAssertTrue(try WAVHeaderRepair.repairIfNeeded(at: url))

        let repaired = try AVAudioFile(forReading: url)
        XCTAssertEqual(repaired.length, 9_600 - 2_000)
    }

    func testLeavesForeignWAVWithTrailingMetadataChunkAlone() throws {
        let url = temporaryDirectory.appendingPathComponent("foreign.wav")
        try writeMonoWAV(to: url, sampleRate: 48_000, samples: Array(repeating: 0.5, count: 9_600))

        // Imported WAVs can carry metadata chunks after the data chunk, so the
        // declared data size is legitimately smaller than the remaining bytes.
        // "Repairing" such a file would decode the metadata as PCM.
        let handle = try FileHandle(forUpdating: url)
        _ = try handle.seekToEnd()
        var trailing = Data("LIST".utf8)
        trailing.append(contentsOf: withUnsafeBytes(of: UInt32(16).littleEndian) { Data($0) })
        trailing.append(Data(repeating: 0x55, count: 16))
        try handle.write(contentsOf: trailing)
        try handle.close()

        XCTAssertFalse(try WAVHeaderRepair.repairIfNeeded(at: url))
        XCTAssertEqual(try AVAudioFile(forReading: url).length, 9_600)
    }

    func testNonWAVFileThrows() throws {
        let url = temporaryDirectory.appendingPathComponent("not-audio.wav")
        try Data(repeating: 0x41, count: 256).write(to: url)

        XCTAssertThrowsError(try WAVHeaderRepair.repairIfNeeded(at: url))
    }

    /// Rewrites the size fields the way a SIGKILL'd AVAudioFile leaves them on
    /// disk (verified experimentally): the RIFF size covers only the chunks up
    /// to the data header, and the data chunk declares 0 bytes.
    private func zeroHeaderSizes(at url: URL) throws {
        let info = try WAVHeaderRepair.probe(at: url)
        let handle = try FileHandle(forUpdating: url)
        defer { try? handle.close() }
        let headerOnlyRIFFSize = UInt32(info.dataSizeFieldOffset - 4)
        try handle.seek(toOffset: 4)
        try handle.write(contentsOf: withUnsafeBytes(of: headerOnlyRIFFSize.littleEndian) { Data($0) })
        try handle.seek(toOffset: UInt64(info.dataSizeFieldOffset))
        try handle.write(contentsOf: Data([0, 0, 0, 0]))
    }

    private func writeMonoWAV(to url: URL, sampleRate: Double, samples: [Float]) throws {
        let format = try XCTUnwrap(AVAudioFormat(
            commonFormat: .pcmFormatFloat32,
            sampleRate: sampleRate,
            channels: 1,
            interleaved: false
        ))
        let file = try AVAudioFile(
            forWriting: url,
            settings: format.settings,
            commonFormat: format.commonFormat,
            interleaved: format.isInterleaved
        )
        let buffer = try XCTUnwrap(AVAudioPCMBuffer(
            pcmFormat: format,
            frameCapacity: AVAudioFrameCount(samples.count)
        ))
        buffer.frameLength = AVAudioFrameCount(samples.count)
        let channelData = try XCTUnwrap(buffer.floatChannelData?[0])
        samples.withUnsafeBufferPointer { pointer in
            guard let baseAddress = pointer.baseAddress else { return }
            channelData.update(from: baseAddress, count: samples.count)
        }
        try file.write(from: buffer)
        file.close()
    }
}
