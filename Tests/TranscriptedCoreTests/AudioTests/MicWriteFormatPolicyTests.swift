import Foundation
import AVFoundation
import XCTest
@testable import TranscriptedCore

/// Promise: a mic buffer whose sample rate no longer matches the recording
/// file is recovered onto a new segment, not counted as a fatal write.
/// Synthetic only — no engine or `inputNode` is built, so this does not
/// prove a Bluetooth headset as the default input.
final class MicWriteFormatPolicyTests: XCTestCase {
    private struct WriteFailure: Error {}

    func testMatchingMonoBufferIsWritten() {
        XCTAssertEqual(
            MicWriteFormatPolicy.decision(
                bufferSampleRate: 48_000,
                bufferChannelCount: 1,
                tapSampleRate: 48_000,
                tapChannelCount: 1,
                fileSampleRate: 48_000,
                fileChannelCount: 1
            ),
            .write
        )
    }

    func testNearlyEqualRatesStillWrite() {
        XCTAssertEqual(
            MicWriteFormatPolicy.decision(
                bufferSampleRate: 48_000.4,
                bufferChannelCount: 1,
                tapSampleRate: 48_000,
                tapChannelCount: 1,
                fileSampleRate: 47_999.6,
                fileChannelCount: 1
            ),
            .write
        )
    }

    func testLiveRateChangeRecoversInsteadOfFailingTheWrite() {
        XCTAssertEqual(
            MicWriteFormatPolicy.decision(
                bufferSampleRate: 24_000,
                bufferChannelCount: 1,
                tapSampleRate: 48_000,
                tapChannelCount: 1,
                fileSampleRate: 48_000,
                fileChannelCount: 1
            ),
            .recover,
            "HFP / default-input swap delivers a new rate into the old file"
        )
    }

    func testStaleTapAfterWriterSwapIsDropped() {
        XCTAssertEqual(
            MicWriteFormatPolicy.decision(
                bufferSampleRate: 48_000,
                bufferChannelCount: 1,
                tapSampleRate: 48_000,
                tapChannelCount: 1,
                fileSampleRate: 24_000,
                fileChannelCount: 1
            ),
            .dropStale,
            "in-flight buffers from the old tap must not recover again"
        )
    }

    func testStereoTapThatMatchesTheMonoFileIsWritten() {
        XCTAssertEqual(
            MicWriteFormatPolicy.decision(
                bufferSampleRate: 48_000,
                bufferChannelCount: 2,
                tapSampleRate: 48_000,
                tapChannelCount: 2,
                fileSampleRate: 48_000,
                fileChannelCount: 1
            ),
            .write
        )
    }

    func testParamErrAndUnsupportedFormatAreFormatMismatches() {
        let paramErr = NSError(domain: NSOSStatusErrorDomain, code: -50)
        let fmt = NSError(domain: NSOSStatusErrorDomain, code: 0x666D743F)
        XCTAssertTrue(MicWriteFormatPolicy.isFormatMismatchError(paramErr))
        XCTAssertTrue(MicWriteFormatPolicy.isFormatMismatchError(fmt))
        XCTAssertFalse(MicWriteFormatPolicy.isFormatMismatchError(WriteFailure()))
    }

    func testMismatchedMicBufferRecoversAndKeepsRecording() throws {
        let harness = try startRecording(rate: 48_000)
        let recovered = LockedGenerations()
        harness.audio.micFormatRecoveryHandlerForTesting = { recovered.append($0) }

        harness.audio.handleMicBuffer(
            makeBuffer(rate: 24_000),
            writeContext: harness.writeContext
        )
        harness.audio.micAudioFileQueue.sync {}

        XCTAssertFalse(recovered.value.isEmpty, "the live tap must be recovered onto a new segment")
        XCTAssertEqual(recovered.value.first, harness.audio.recordingSessionGeneration)
        XCTAssertTrue(harness.audio.isRecording, "format mismatch must not end the meeting")
        XCTAssertNil(harness.audio.internalStopCause)
        XCTAssertNil(harness.audio.error)
        XCTAssertEqual(harness.audio.consecutiveMicWriteErrors, 0)
    }

    func testTenMismatchedBuffersDoNotTripTheWriteCap() throws {
        let harness = try startRecording(rate: 48_000)
        let recovered = LockedGenerations()
        harness.audio.micFormatRecoveryHandlerForTesting = { recovered.append($0) }

        for _ in 0..<harness.audio.maxConsecutiveWriteErrors {
            harness.audio.handleMicBuffer(
                makeBuffer(rate: 16_000),
                writeContext: harness.writeContext
            )
        }
        harness.audio.micAudioFileQueue.sync {}
        settleMainQueue()

        XCTAssertGreaterThanOrEqual(recovered.value.count, 1)
        XCTAssertTrue(harness.audio.isRecording)
        XCTAssertNil(harness.audio.internalStopCause)
        XCTAssertEqual(harness.audio.consecutiveMicWriteErrors, 0)
    }

    func testStaleBufferAfterWriterSwapDoesNotRecover() throws {
        let harness = try startRecording(rate: 24_000)
        let recovered = LockedGenerations()
        harness.audio.micFormatRecoveryHandlerForTesting = { recovered.append($0) }
        let staleContext = MicPCMWriteContext(
            generation: harness.audio.recordingSessionGeneration,
            monoFormat: format(rate: 48_000),
            inputChannelCount: 1
        )

        harness.audio.handleMicBuffer(makeBuffer(rate: 48_000), writeContext: staleContext)
        harness.audio.micAudioFileQueue.sync {}

        XCTAssertEqual(recovered.value.count, 0, "the old tap must be dropped, not recovered again")
        XCTAssertTrue(harness.audio.isRecording)
        XCTAssertNil(harness.audio.internalStopCause)
    }

    func testWriteFailuresDuringMicRecoveryDoNotStopTheRecording() throws {
        let audio = try makeRecordingAudio()
        audio._micRecoverySessionGeneration = audio.recordingSessionGeneration

        for _ in 1...audio.maxConsecutiveWriteErrors {
            XCTAssertFalse(
                audio.recordMicWriteFailure(WriteFailure()),
                "errors from the outgoing tap must not trip the cap"
            )
        }
        settleMainQueue()

        XCTAssertTrue(audio.isRecording)
        XCTAssertNil(audio.internalStopCause)
        audio._micRecoverySessionGeneration = nil
    }

    func testMatchingBufferStillReachesTheMicFile() throws {
        let harness = try startRecording(rate: 48_000)
        let recovered = LockedGenerations()
        harness.audio.micFormatRecoveryHandlerForTesting = { recovered.append($0) }

        harness.audio.handleMicBuffer(
            makeBuffer(rate: 48_000, frames: 64),
            writeContext: harness.writeContext
        )
        harness.audio.micAudioFileQueue.sync {}

        XCTAssertEqual(recovered.value.count, 0)
        XCTAssertEqual(harness.writer.length, 64)
        XCTAssertTrue(harness.audio.isRecording)
    }

    private final class LockedGenerations: @unchecked Sendable {
        private let lock = NSLock()
        private var stored: [UInt64] = []

        var value: [UInt64] {
            lock.lock()
            defer { lock.unlock() }
            return stored
        }

        func append(_ generation: UInt64) {
            lock.lock()
            stored.append(generation)
            lock.unlock()
        }
    }

    // MARK: - Harness

    private struct Harness {
        let audio: Audio
        let writer: AVAudioFile
        let writeContext: MicPCMWriteContext
    }

    private func makeRecordingAudio() throws -> Audio {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("MicWriteFormatPolicyTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: root) }
        let audio = Audio(paths: CoreStoragePaths(
            transcripts: root.appendingPathComponent("captures/meetings", isDirectory: true),
            speakerDB: root.appendingPathComponent("state/speakers.sqlite"),
            statsDB: root.appendingPathComponent("state/stats.sqlite"),
            failedQueue: root.appendingPathComponent("state/failed_transcriptions.json"),
            speakerClips: root.appendingPathComponent("tmp/recordings/speaker_clips", isDirectory: true),
            audioCaptures: root.appendingPathComponent("tmp/recordings", isDirectory: true),
            logs: root.appendingPathComponent("logs", isDirectory: true)
        ))
        audio.prepareForNewRecordingStart()
        audio.realtimeAGC = nil
        audio.isRecording = true
        return audio
    }

    private func startRecording(rate: Double) throws -> Harness {
        let audio = try makeRecordingAudio()
        let generation = audio.recordingSessionGeneration
        let fmt = format(rate: rate)
        let url = audio.paths.audioCaptures.appendingPathComponent("mic-\(UUID().uuidString).wav")
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        let writer = try AVAudioFile(
            forWriting: url,
            settings: fmt.settings,
            commonFormat: fmt.commonFormat,
            interleaved: fmt.isInterleaved
        )
        XCTAssertTrue(
            audio.micAudioFileOwnership.installSessionWriter(writer, generation: generation).didInstall
        )
        return Harness(
            audio: audio,
            writer: writer,
            writeContext: MicPCMWriteContext(
                generation: generation,
                monoFormat: fmt,
                inputChannelCount: 1
            )
        )
    }

    private func format(rate: Double) -> AVAudioFormat {
        AVAudioFormat(
            commonFormat: .pcmFormatFloat32,
            sampleRate: rate,
            channels: 1,
            interleaved: false
        )!
    }

    private func makeBuffer(rate: Double, frames: AVAudioFrameCount = 128) -> AVAudioPCMBuffer {
        let buffer = AVAudioPCMBuffer(
            pcmFormat: format(rate: rate),
            frameCapacity: frames
        )!
        buffer.frameLength = frames
        buffer.floatChannelData![0].update(repeating: 0.1, count: Int(frames))
        return buffer
    }

    private func settleMainQueue() {
        let settled = expectation(description: "main queue settled")
        DispatchQueue.main.async { settled.fulfill() }
        wait(for: [settled], timeout: 5)
    }
}
