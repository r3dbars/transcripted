#if TRANSCRIPTEDCLI_WITH_MEETING_IMPORT
import AVFoundation
import Darwin
import Foundation
import XCTest
@testable import transcripted_cli

final class MeetingImportWorkflowTests: XCTestCase {
    func testFloatWAVDecodeIncludesUnalignedFinalFrames() async throws {
        let root = try temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        for frameCount in [32_000, 32_001, 48_003] {
            let input = root.appendingPathComponent("\(frameCount).wav")
            try writeAudio(to: input, sampleRate: 16_000, channels: 1, seconds: Double(frameCount) / 16_000)
            let decoded = try await TranscribeMediaLoader.loadSamples(from: input)
            XCTAssertEqual(decoded.samples.count, frameCount)
            XCTAssertEqual(decoded.samples.last!, Float(sin(Double(frameCount - 1) * 440 * 2 * .pi / 16_000)) * 0.2, accuracy: 0.00001)
        }
    }

    func testRegularInputValidationRejectsMissingDirectoryAndFIFO() throws {
        let root = try temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        XCTAssertThrowsError(try MeetingImportWorkflow.validatedInput(root.path))
        XCTAssertThrowsError(try MeetingImportWorkflow.validatedInput(root.appendingPathComponent("missing.wav").path))
        let fifo = root.appendingPathComponent("pipe.wav")
        XCTAssertEqual(mkfifo(fifo.path, 0o600), 0)
        XCTAssertThrowsError(try MeetingImportWorkflow.validatedInput(fifo.path))
        let file = root.appendingPathComponent("ää.wav")
        try Data([1]).write(to: file)
        let link = root.appendingPathComponent("input-link")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: file)
        XCTAssertEqual(try MeetingImportWorkflow.validatedInput(link.path), file.resolvingSymlinksInPath())
    }

    func testIncompleteExplicitModelsFailInsteadOfDownloadingOrFallingBack() throws {
        let root = try temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        for noDownload in [true, false] {
            XCTAssertThrowsError(try MeetingImportModels.resolve(modelsDir: root.path, diarizationModelsDir: nil, noDownload: noDownload))
            XCTAssertThrowsError(try MeetingImportModels.resolve(modelsDir: nil, diarizationModelsDir: root.path, noDownload: noDownload))
        }
        XCTAssertTrue(try FileManager.default.contentsOfDirectory(atPath: root.path).isEmpty)
    }

    func testNormalizeStereo44100PreservesSource() async throws {
        let root = try temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let input = root.appendingPathComponent("source.wav")
        try writeAudio(to: input, sampleRate: 44_100, channels: 2, seconds: 3)
        let original = try Data(contentsOf: input)
        let output = root.appendingPathComponent("normalized.wav")
        try await MeetingImportWorkflow.normalize(input, to: output)
        XCTAssertEqual(try Data(contentsOf: input), original)
        let file = try AVAudioFile(forReading: output)
        XCTAssertEqual(file.processingFormat.sampleRate, 16_000)
        XCTAssertEqual(file.processingFormat.channelCount, 1)
        XCTAssertEqual(Double(file.length) / 16_000, 3, accuracy: 0.05)
    }

    func testShortAndCorruptInputLeaveNoNormalizedArtifact() async throws {
        let root = try temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let short = root.appendingPathComponent("short.wav")
        try writeAudio(to: short, sampleRate: 16_000, channels: 1, seconds: 0.5)
        let corrupt = root.appendingPathComponent("corrupt.wav")
        try Data("not audio".utf8).write(to: corrupt)
        for input in [short, corrupt] {
            let original = try Data(contentsOf: input)
            let output = root.appendingPathComponent("normalized.wav")
            do {
                try await MeetingImportWorkflow.normalize(input, to: output)
                XCTFail("Should reject invalid/short audio")
            } catch {}
            XCTAssertEqual(try Data(contentsOf: input), original)
            XCTAssertFalse(FileManager.default.fileExists(atPath: output.path))
        }
    }

    func testCancelledDecodeDoesNotFallBackOrWriteOutput() async throws {
        let root = try temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let input = root.appendingPathComponent("source.wav")
        try writeAudio(to: input, sampleRate: 48_000, channels: 1, seconds: 3)
        let output = root.appendingPathComponent("normalized.wav")
        let original = try Data(contentsOf: input)
        let task = Task {
            withUnsafeCurrentTask { $0?.cancel() }
            try await MeetingImportWorkflow.normalize(input, to: output)
        }
        do { try await task.value; XCTFail("Expected cancellation") }
        catch { XCTAssertTrue(error is CancellationError) }
        XCTAssertFalse(FileManager.default.fileExists(atPath: output.path))
        XCTAssertEqual(try Data(contentsOf: input), original)
    }

    private func temporaryRoot() throws -> URL {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("CLIWorkflowTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
        return root
    }

    private func writeAudio(to url: URL, sampleRate: Double, channels: AVAudioChannelCount, seconds: Double) throws {
        let format = try XCTUnwrap(AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: sampleRate, channels: channels, interleaved: false))
        let count = AVAudioFrameCount((sampleRate * seconds).rounded())
        let buffer = try XCTUnwrap(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: count))
        buffer.frameLength = count
        for channel in 0..<Int(channels) {
            for index in 0..<Int(count) {
                buffer.floatChannelData![channel][index] = Float(sin(Double(index) * 440 * 2 * .pi / sampleRate)) * 0.2
            }
        }
        let file = try AVAudioFile(forWriting: url, settings: format.settings)
        try file.write(from: buffer)
    }
}
#endif
