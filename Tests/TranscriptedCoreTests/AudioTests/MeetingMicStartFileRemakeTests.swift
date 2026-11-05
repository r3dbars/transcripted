import XCTest
@preconcurrency import AVFoundation
@testable import TranscriptedCore

/// Real owned WAVs and the production remake/Stop paths, without preparing a
/// capture graph. These tests do not establish whether a failed native engine
/// start can deliver frames before it throws, or pause inside AVFoundation open.
final class MeetingMicStartFileRemakeTests: XCTestCase {
    func testEmptyFileRemakeUsesSettledRateAndKeepsJournalIdentity() throws {
        let fixture = try MicStartFileFixture()
        defer { fixture.close() }
        let journal = try fixture.audio.recordingJournal.begin(primaryMicURL: fixture.url)
        fixture.audio.journalSession = journal
        let journalURL = fixture.url.deletingPathExtension()
            .appendingPathExtension("recording.json")
        let journalBefore = try Data(contentsOf: journalURL)

        let context = try fixture.remake(rate: 24_000, channels: 2)
        let writer = try XCTUnwrap(fixture.currentWriter)
        XCTAssertFalse(writer === fixture.originalWriter)
        XCTAssertEqual(context.generation, fixture.generation)
        XCTAssertEqual(context.monoFormat.sampleRate, 24_000)
        XCTAssertEqual(context.monoFormat.channelCount, 1)
        XCTAssertEqual(context.inputChannelCount, 2)
        XCTAssertEqual(writer.processingFormat.sampleRate, 24_000)
        XCTAssertEqual(fixture.audio.monoOutputFormat?.sampleRate, 24_000)
        XCTAssertEqual(fixture.audio.inputChannelCount, 2)
        XCTAssertEqual(fixture.audio.originalMicAudioFileURL, fixture.url)
        XCTAssertEqual(try Data(contentsOf: journalURL), journalBefore)

        try fixture.audio.micAudioFileQueue.sync {
            try writer.write(from: fixture.buffer(writer: writer, frames: 240, value: 0.25))
            writer.close()
        }
        let saved = try AVAudioFile(forReading: fixture.url)
        XCTAssertEqual(saved.fileFormat.sampleRate, 24_000)
        XCTAssertEqual(saved.fileFormat.channelCount, 1)
        XCTAssertEqual(saved.length, 240)
        XCTAssertEqual(try fixture.firstSample(saved), 0.25, accuracy: 0.0001)
    }

    func testStaleGenerationCannotReplaceCurrentFileOrWriter() throws {
        let fixture = try MicStartFileFixture()
        defer { fixture.close() }
        _ = fixture.audio.beginRecordingSessionGeneration()

        XCTAssertThrowsError(try fixture.remake(rate: 24_000)) { error in
            XCTAssertTrue(error is AudioCaptureStaleSessionError)
        }
        XCTAssertTrue(fixture.currentWriter === fixture.originalWriter)
        XCTAssertEqual(fixture.currentWriter?.processingFormat.sampleRate, 48_000)
    }

    func testDifferentWriterGenerationCannotBeTakenByRemake() throws {
        let fixture = try MicStartFileFixture(writerGeneration: 20)
        defer { fixture.close() }

        XCTAssertThrowsError(try fixture.remake(rate: 24_000)) { error in
            XCTAssertTrue(error is AudioCaptureStaleSessionError)
        }
        XCTAssertTrue(fixture.currentWriter === fixture.originalWriter)
        XCTAssertEqual(fixture.audio.micAudioFileOwnership.generation, 20)
    }

    func testActualOpenFailureLeavesNoInstalledReplacement() throws {
        let fixture = try MicStartFileFixture()
        defer { fixture.close() }
        let movedDirectory = fixture.root.appendingPathComponent("moved-owned-captures")
        try FileManager.default.moveItem(at: fixture.url.deletingLastPathComponent(), to: movedDirectory)

        XCTAssertThrowsError(try fixture.remake(rate: 24_000))
        XCTAssertNil(fixture.currentWriter)
        XCTAssertFalse(FileManager.default.fileExists(atPath: fixture.url.path))
        let retainedOriginal = try AVAudioFile(
            forReading: movedDirectory.appendingPathComponent(fixture.url.lastPathComponent)
        )
        XCTAssertEqual(retainedOriginal.fileFormat.sampleRate, 48_000)
        XCTAssertEqual(retainedOriginal.length, 0)
    }

    @MainActor
    func testCompletedStopCannotBeFollowedByWriterResurrection() async throws {
        let fixture = try MicStartFileFixture()
        defer { fixture.close() }
        let completed = expectation(description: "owned Stop finalized")
        fixture.audio.onRecordingComplete = { _, _ in completed.fulfill() }

        fixture.audio.stop()
        await fulfillment(of: [completed], timeout: 5)
        fixture.audio.onRecordingComplete = nil

        XCTAssertNil(fixture.currentWriter)
        XCTAssertThrowsError(try fixture.remake(rate: 24_000)) { error in
            XCTAssertTrue(error is AudioCaptureStaleSessionError)
        }
        XCTAssertNil(fixture.currentWriter)
        let saved = try AVAudioFile(forReading: fixture.url)
        XCTAssertEqual(saved.fileFormat.sampleRate, 48_000)
        XCTAssertEqual(saved.length, 0)
    }

    @MainActor
    func testStopClosesRemadeWriterAfterItsAdmittedWriteFinishes() async throws {
        let fixture = try MicStartFileFixture()
        defer { fixture.close() }
        _ = try fixture.remake(rate: 24_000)
        let writer = try XCTUnwrap(fixture.currentWriter)
        let buffer = try fixture.buffer(writer: writer, frames: 240, value: 0.5)
        let admitted = expectation(description: "owned write admitted")
        let releaseWrite = DispatchSemaphore(value: 0)
        defer { releaseWrite.signal() }
        let outcome = MicStartWriteOutcome()
        fixture.audio.micAudioFileQueue.async {
            admitted.fulfill()
            releaseWrite.wait()
            do { try writer.write(from: buffer) } catch { outcome.store(error) }
        }
        await fulfillment(of: [admitted], timeout: 5)
        let completed = expectation(description: "Stop drained real writer")
        fixture.audio.onRecordingComplete = { _, _ in completed.fulfill() }
        fixture.audio.stop()
        releaseWrite.signal()
        await fulfillment(of: [completed], timeout: 5)
        fixture.audio.onRecordingComplete = nil

        XCTAssertNil(outcome.error)
        XCTAssertNil(fixture.currentWriter)
        let saved = try AVAudioFile(forReading: fixture.url)
        XCTAssertEqual(saved.fileFormat.sampleRate, 24_000)
        XCTAssertEqual(saved.length, 240)
        XCTAssertEqual(try fixture.firstSample(saved), 0.5, accuracy: 0.0001)
    }

    @MainActor
    func testStopWhileRemakeIsDispatchedBehindQueueBlockerCannotResurrectWriter() async throws {
        let fixture = try MicStartFileFixture()
        defer { fixture.close() }
        let queueBlocked = expectation(description: "owned file queue blocked")
        let releaseQueue = DispatchSemaphore(value: 0)
        defer { releaseQueue.signal() }
        fixture.audio.micAudioFileQueue.async {
            queueBlocked.fulfill()
            releaseQueue.wait()
        }
        await fulfillment(of: [queueBlocked], timeout: 5)
        let dispatched = expectation(description: "remake dispatched")
        let remakeFinished = expectation(description: "remake returned")
        let audio = fixture.audio
        let generation = fixture.generation
        let outcome = MicStartWriteOutcome()
        DispatchQueue.global(qos: .utility).async {
            dispatched.fulfill()
            do {
                _ = try audio.remakeMeetingMicStartFile(
                    recordingSnapshot: .init(sampleRate: 24_000, channelCount: 1),
                    sessionGeneration: generation
                )
            } catch { outcome.store(error) }
            remakeFinished.fulfill()
        }
        await fulfillment(of: [dispatched], timeout: 5)
        let stopped = expectation(description: "Stop behind owned file queue finished")
        audio.onRecordingComplete = { _, _ in stopped.fulfill() }
        audio.stop()
        releaseQueue.signal()
        await fulfillment(of: [remakeFinished, stopped], timeout: 5)
        audio.onRecordingComplete = nil

        if let error = outcome.error { XCTAssertTrue(error is AudioCaptureStaleSessionError) }
        XCTAssertNil(fixture.currentWriter)
        XCTAssertFalse(audio.micAudioFileOwnership.recordingOwnsMicFile(generation))
        XCTAssertNil(audio.engine)
        XCTAssertNil(audio.inputNode)
        XCTAssertTrue(FileManager.default.fileExists(atPath: fixture.url.path))
    }
}

private final class MicStartWriteOutcome: @unchecked Sendable {
    private let lock = NSLock()
    private var storedError: Error?

    var error: Error? {
        lock.lock()
        defer { lock.unlock() }
        return storedError
    }

    func store(_ error: Error) {
        lock.lock()
        storedError = error
        lock.unlock()
    }
}

private final class MicStartFileFixture {
    let root: URL
    let audio: Audio
    let url: URL
    let generation: UInt64 = 11
    let originalWriter: AVAudioFile

    init(writerGeneration: UInt64 = 11) throws {
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("MeetingMicStartFileRemake-\(UUID().uuidString)", isDirectory: true)
        let captures = root.appendingPathComponent("captures", isDirectory: true)
        try FileManager.default.createDirectory(at: captures, withIntermediateDirectories: true)
        let paths = CoreStoragePaths(
            transcripts: root.appendingPathComponent("transcripts"),
            speakerDB: root.appendingPathComponent("speakers.sqlite"),
            statsDB: root.appendingPathComponent("stats.sqlite"),
            failedQueue: root.appendingPathComponent("failed.json"),
            speakerClips: root.appendingPathComponent("clips"),
            audioCaptures: captures,
            logs: root.appendingPathComponent("logs")
        )
        audio = Audio(
            paths: paths,
            systemAudioCaptureForTesting: nil,
            systemAudioCaptureFactoryForTesting: { nil },
            sleepWakeNotifications: .init(
                center: NotificationCenter(),
                willSleepName: .init("OwnedMicProofSleep"),
                didWakeName: .init("OwnedMicProofWake")
            )
        )
        audio.recordingSessionGeneration = generation
        url = captures.appendingPathComponent("meeting_owned_mic.wav")
        let format = try AudioRecordingFormatPolicy.makeMonoOutputFormat(sampleRate: 48_000)
        originalWriter = try AVAudioFile(
            forWriting: url, settings: format.settings,
            commonFormat: format.commonFormat, interleaved: format.isInterleaved
        )
        let installed = audio.micAudioFileQueue.sync {
            audio.micAudioFileOwnership.installSessionWriter(originalWriter, generation: writerGeneration)
        }
        guard installed.didInstall else { throw CocoaError(.fileWriteUnknown) }
        audio.originalMicAudioFileURL = url
        audio.micSegments = [MicRecordingSegment(url: url)]
    }

    var currentWriter: AVAudioFile? { audio.micAudioFileOwnership.writer }

    func remake(rate: Double, channels: AVAudioChannelCount = 1) throws -> MicPCMWriteContext {
        try audio.remakeMeetingMicStartFile(
            recordingSnapshot: .init(sampleRate: rate, channelCount: channels),
            sessionGeneration: generation
        )
    }

    func buffer(writer: AVAudioFile, frames: AVAudioFrameCount, value: Float) throws -> AVAudioPCMBuffer {
        let buffer = try XCTUnwrap(AVAudioPCMBuffer(pcmFormat: writer.processingFormat, frameCapacity: frames))
        buffer.frameLength = frames
        let samples = try XCTUnwrap(buffer.floatChannelData?[0])
        samples.initialize(repeating: value, count: Int(frames))
        return buffer
    }

    func firstSample(_ file: AVAudioFile) throws -> Float {
        let buffer = try XCTUnwrap(AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: 1))
        try file.read(into: buffer)
        return try XCTUnwrap(buffer.floatChannelData?[0]).pointee
    }

    func close() {
        audio.micAudioFileQueue.sync { audio.micAudioFileOwnership.writer?.close() }
        originalWriter.close()
        guard root.lastPathComponent.hasPrefix("MeetingMicStartFileRemake-"),
              root.deletingLastPathComponent().standardizedFileURL
                == FileManager.default.temporaryDirectory.standardizedFileURL else {
            preconditionFailure("Refusing to remove outside owned mic proof root")
        }
        try? FileManager.default.removeItem(at: root)
    }
}
