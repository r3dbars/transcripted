import XCTest
import AVFoundation
@testable import TranscriptedCore

final class SystemAudioWriteTimelineTests: XCTestCase {
    private func writer(_ directory: URL, _ leaf: String) throws -> AVAudioFile {
        let format = AVAudioFormat(standardFormatWithSampleRate: 48_000, channels: 2)!
        return try AVAudioFile(forWriting: directory.appendingPathComponent(leaf), settings: format.settings)
    }

    private func buffer(_ writer: AVAudioFile, frames: AVAudioFrameCount = 128) -> AVAudioPCMBuffer {
        let buffer = AVAudioPCMBuffer(pcmFormat: writer.processingFormat, frameCapacity: frames)!
        buffer.frameLength = frames
        for item in UnsafeMutableAudioBufferListPointer(buffer.mutableAudioBufferList) {
            memset(item.mData!, 0, Int(item.mDataByteSize))
        }
        return buffer
    }

    private func timing(_ host: UInt64, _ sample: Double) -> SystemAudioBufferTiming {
        .init(firstSampleHostTime: host, sampleTime: sample, sampleRate: 48_000, continuityID: 1)
    }

    func testRealWriterPositionsDefineTheCommittedSpanAndFinalTailIsUnmapped() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let writer = try writer(directory, "owned.wav")
        defer { writer.close() }
        let journal = SystemAudioWriteTimeline()
        journal.install(writer: writer, generation: 12)
        XCTAssertNil(journal.takeFinished(), "a live journal is never handed to transcription")
        try journal.write(buffer(writer), to: writer, timing: timing(10_000, 0))
        try journal.write(buffer(writer), to: writer, timing: timing(20_000, 128))
        XCTAssertEqual(writer.framePosition, 256)
        journal.finish(writer: writer)
        let timeline = try XCTUnwrap(journal.takeFinished())
        let span = try XCTUnwrap(timeline.map(startHostTime: 10_000, endHostTime: 20_000).first)
        XCTAssertEqual(span.start, 0)
        XCTAssertEqual(span.end, 128.0 / 48_000)
        XCTAssertEqual(timeline.identity.generation, 12)
        XCTAssertEqual(timeline.unmappedFrameCount, 128)
        XCTAssertNil(journal.takeFinished(), "the immutable handoff is one-shot")
    }

    func testRealSilenceWriteKeepsFileCoordinatesButCannotBecomeAnAnchor() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let writer = try writer(directory, "owned.wav")
        defer { writer.close() }
        let journal = SystemAudioWriteTimeline()
        journal.install(writer: writer, generation: 12)
        try journal.write(buffer(writer), to: writer, timing: timing(10_000, 0))
        try journal.write(buffer(writer, frames: 480), to: writer)
        try journal.write(buffer(writer), to: writer, timing: timing(30_000, 256))
        try journal.write(buffer(writer), to: writer, timing: timing(40_000, 384))
        journal.finish(writer: writer)
        let timeline = try XCTUnwrap(journal.takeFinished())
        XCTAssertTrue(timeline.map(startHostTime: 10_000, endHostTime: 30_000).isEmpty)
        XCTAssertEqual(timeline.map(startHostTime: 30_000, endHostTime: 40_000).first?.start, 608.0 / 48_000)
    }

    func testAnotherWriterCannotPublishOrSupplyTheOriginalWritersTimeline() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let writer = try writer(directory, "owned.wav"), unrelated = try self.writer(directory, "unrelated.wav")
        defer { writer.close(); unrelated.close() }
        let journal = SystemAudioWriteTimeline()
        journal.install(writer: writer, generation: 12)
        try journal.write(buffer(unrelated), to: unrelated, timing: timing(1, 0))
        journal.finish(writer: unrelated)
        XCTAssertNil(journal.takeFinished())
        try journal.write(buffer(writer), to: writer, timing: timing(10_000, 0))
        try journal.write(buffer(writer), to: writer, timing: timing(20_000, 128))
        journal.finish(writer: writer)
        XCTAssertEqual(journal.takeFinished()?.unmappedFrameCount, 128)
    }

    func testAdmittedFinishingBuffersPublishOnlyAfterTheirFileQueueDrains() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let writer = try writer(directory, "owned.wav")
        defer { writer.close() }
        let capture = CoreAudioSystemAudioCapture(hardwareHooks: .init(
            prepare: { writer.processingFormat }, start: {}, stop: {}, currentFormat: { writer.processingFormat }
        ), clock: { 100 })
        let attempt = SystemAudioCaptureStartAttempt(capture: capture)
        let queue = DispatchQueue(label: "owned.test.system-file")
        queue.sync { attempt.writeTimeline.install(writer: writer, generation: 12) }
        attempt.beginFinishing()
        attempt.enqueueFinishingBuffer(buffer(writer), timing: timing(10_000, 0), writer: writer, queue: queue) { _ in
            XCTFail("owned finishing write failed")
        }
        attempt.enqueueFinishingBuffer(buffer(writer), timing: timing(20_000, 128), writer: writer, queue: queue) { _ in
            XCTFail("owned finishing write failed")
        }
        queue.sync { attempt.writeTimeline.finish(writer: writer) }
        let timeline = try XCTUnwrap(attempt.writeTimeline.takeFinished())
        XCTAssertEqual(writer.framePosition, 256)
        XCTAssertEqual(timeline.map(startHostTime: 10_000, endHostTime: 20_000).first?.end, 128.0 / 48_000)
        XCTAssertEqual(timeline.unmappedFrameCount, 128)
    }
}
