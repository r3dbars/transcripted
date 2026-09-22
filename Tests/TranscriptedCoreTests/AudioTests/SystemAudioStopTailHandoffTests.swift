import XCTest
import AVFoundation
@testable import TranscriptedCore

/// Lock-owned generation and callback counts shared with the capture queue.
private final class LockedCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var stored: UInt64

    init(_ value: UInt64) { stored = value }

    var value: UInt64 {
        lock.lock()
        defer { lock.unlock() }
        return stored
    }

    func advance() {
        lock.lock()
        stored += 1
        lock.unlock()
    }
}

/// Host-side pin for the recording-end tail handoff.
///
/// `CoreAudioSystemAudioCaptureTests` covers the backend drain and the
/// attempt's tail-admission window in isolation. What no test covered is the
/// wiring in `Audio.stop()` that makes those two pieces add up to "the last
/// slice of the recording reaches the WAV":
///
/// 1. `beginFinishing()` must run *before* the recording generation advances.
///    Every buffer the backend's 10 ms consumer timer delivers between the
///    generation bump and the asynchronously scheduled HAL stop reaches the
///    host with a stale generation, and the only path that still writes those
///    is the finishing handoff. If admission is not already armed, they are
///    dropped without a diagnostic.
/// 2. Stop must *finish and drain* the capture, not cancel it. Cancellation
///    deliberately discards queued PCM.
/// 3. The writer must close on the same serial file queue the tail writes were
///    enqueued on, after `stopSystem` returns, so the drained tail is never
///    written to a closed file.
///
/// Each of those is a one- or two-line ordering inside a 3.5k-line file, and
/// losing any of them silently truncates the end of every saved meeting —
/// nothing else in CI would notice, because no automated job exercises real
/// capture hardware.
final class SystemAudioStopTailHandoffTests: XCTestCase {
    private static let format = AVAudioFormat(
        commonFormat: .pcmFormatFloat32,
        sampleRate: 48000,
        channels: 2,
        interleaved: false
    )!

    private func makeCapture() -> CoreAudioSystemAudioCapture {
        let format = Self.format
        return CoreAudioSystemAudioCapture(
            hardwareHooks: .init(
                prepare: { format },
                start: {},
                stop: {},
                currentFormat: { format }
            ),
            clock: { 100 }
        )
    }

    private func makeBuffer(marker: Float) -> AVAudioPCMBuffer {
        let result = AVAudioPCMBuffer(pcmFormat: Self.format, frameCapacity: 8)!
        result.frameLength = 8
        for item in UnsafeMutableAudioBufferListPointer(result.mutableAudioBufferList) {
            memset(item.mData!, 0, Int(item.mDataByteSize))
        }
        result.floatChannelData![0][0] = marker
        result.floatChannelData![1][0] = -marker
        return result
    }

    private func makeTemporaryDirectory() throws -> URL {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(
            at: directory,
            withIntermediateDirectories: true
        )
        addTeardownBlock { try? FileManager.default.removeItem(at: directory) }
        return directory
    }

    /// End-to-end through the real stop scheduler: PCM still sitting in the
    /// backend ring when the user presses Stop has to be in the saved WAV.
    ///
    /// This is the failure the Core Audio tap change was held on: the host
    /// closes normal writer admission at stop, so the tail only survives if
    /// the finishing handoff is armed first *and* `AudioStopCleanup` closes
    /// the writer behind the drained writes rather than ahead of them.
    func testStopCleanupWritesTheDrainedRingTailBeforeClosingTheWriter() throws {
        try assertStopPreservesTail(drainBeforeCleanup: false)
    }

    func testEarlyFinishingAdmissionPreservesBuffersBeforeBackendStop() throws {
        try assertStopPreservesTail(drainBeforeCleanup: true)
    }

    private func assertStopPreservesTail(drainBeforeCleanup: Bool) throws {
        let capture = makeCapture()
        let attempt = SystemAudioCaptureStartAttempt(capture: capture)
        let url = try makeTemporaryDirectory().appendingPathComponent("system.wav")
        let writer = try AVAudioFile(forWriting: url, settings: Self.format.settings)
        let systemFileQueue = DispatchQueue(label: "test.system.writer")

        // Mirrors AudioFileManager's production buffer callback: once the
        // recording generation has advanced, the finishing handoff is the only
        // route to this recording's own writer.
        let sessionGeneration = UInt64(1)
        let recordingGeneration = LockedCounter(sessionGeneration)
        let normalDeliveries = LockedCounter(0)
        let finishingDeliveries = LockedCounter(0)

        try attempt.prepare()
        try attempt.startIfNotCancelled { buffer in
            guard sessionGeneration == recordingGeneration.value else {
                finishingDeliveries.advance()
                attempt.enqueueFinishingBuffer(
                    buffer,
                    writer: writer,
                    queue: systemFileQueue
                ) { error in
                    XCTFail("Tail write failed: \(error)")
                }
                return
            }
            normalDeliveries.advance()
            systemFileQueue.async { try? writer.write(from: buffer) }
        }

        // Hardware hooks disable the consumer timer. Explicitly control both
        // the final queued tail and delivery before asynchronous HAL stop.
        capture.receiveForTesting(makeBuffer(marker: 0.25))
        if !drainBeforeCleanup {
            capture.receiveForTesting(makeBuffer(marker: 0.5))
        }
        XCTAssertEqual(normalDeliveries.value, 0, "Hooked capture must leave both buffers queued until stop")

        // `Audio.stop()`: arm the tail synchronously, then advance the
        // generation, then schedule the asynchronous teardown.
        attempt.beginFinishing()
        recordingGeneration.advance()
        if drainBeforeCleanup {
            // finishAndDrain() arms admission itself, so exercise this earlier
            // consumer delivery separately: only beginFinishing can save it.
            capture.drainForTesting()
            XCTAssertEqual(finishingDeliveries.value, 1)
            capture.receiveForTesting(makeBuffer(marker: 0.5))
        }

        let completed = expectation(description: "stop cleanup completed")
        AudioStopCleanup.schedule(
            group: DispatchGroup(),
            microphoneFileQueue: DispatchQueue(label: "test.mic.writer"),
            systemFileQueue: systemFileQueue,
            stopMicrophone: {},
            stopSystem: { attempt.finishAndDrain() },
            closeMicrophone: {},
            closeSystem: { writer.close() },
            completion: { completed.fulfill() }
        )
        wait(for: [completed], timeout: 5)

        let savedFile = try AVAudioFile(forReading: url)
        XCTAssertEqual(
            savedFile.length,
            16,
            "Both ring buffers must reach the WAV before the writer closes"
        )
        XCTAssertEqual(normalDeliveries.value, 0, "The normal-write path must not satisfy this tail test")
        XCTAssertEqual(finishingDeliveries.value, 2)
        let savedPCM = try XCTUnwrap(AVAudioPCMBuffer(pcmFormat: savedFile.processingFormat, frameCapacity: 16))
        try savedFile.read(into: savedPCM)
        guard savedPCM.frameLength == 16, savedPCM.format.channelCount == 2 else {
            return XCTFail("Expected 16 frames of stereo PCM before inspecting tail markers")
        }
        let channels = try XCTUnwrap(savedPCM.floatChannelData)
        XCTAssertEqual(channels[0][0], 0.25, accuracy: 0.0001)
        XCTAssertEqual(channels[0][8], 0.5, accuracy: 0.0001)
        XCTAssertEqual(channels[1][0], -0.25, accuracy: 0.0001)
        XCTAssertEqual(channels[1][8], -0.5, accuracy: 0.0001)
        XCTAssertFalse(attempt.hasFinalizationFailure)
        XCTAssertFalse(attempt.isDraining)
    }

    /// The same scheduler must still discard the tail when stop is an explicit
    /// cancellation, so a superseded attempt cannot append to a file that a
    /// successor recording has moved on from.
    func testCancelledAttemptDiscardsItsRingTail() throws {
        let capture = makeCapture()
        let attempt = SystemAudioCaptureStartAttempt(capture: capture)
        let url = try makeTemporaryDirectory().appendingPathComponent("cancelled.wav")
        let writer = try AVAudioFile(forWriting: url, settings: Self.format.settings)
        let systemFileQueue = DispatchQueue(label: "test.system.writer")
        let deliveries = LockedCounter(0)

        try attempt.prepare()
        try attempt.startIfNotCancelled { buffer in
            deliveries.advance()
            attempt.enqueueFinishingBuffer(
                buffer,
                writer: writer,
                queue: systemFileQueue
            ) { _ in }
        }
        capture.receiveForTesting(makeBuffer(marker: 0.25))

        attempt.cancel()
        attempt.finishAndDrain()
        systemFileQueue.sync { writer.close() }

        XCTAssertEqual(deliveries.value, 0, "Cancellation must discard queued PCM, not merely reject it at an unarmed writer")
        XCTAssertEqual(try AVAudioFile(forReading: url).length, 0)
    }

    // MARK: - Source-order contract

    private var audioSourceURL: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent() // AudioTests
            .deletingLastPathComponent() // TranscriptedCoreTests
            .deletingLastPathComponent() // Tests
            .deletingLastPathComponent() // repository root
            .appendingPathComponent("Sources/TranscriptedCore/Audio/Audio.swift")
    }

    /// `Audio.stop()` is long enough that the two orderings the tail depends on
    /// are easy to move by accident. Pin them here: no unit test below this
    /// level can observe the order of statements in that function, and no CI
    /// job records real audio to notice the truncation.
    func testStopArmsTheTailHandoffBeforeAdvancingTheRecordingGeneration() throws {
        let lines = try String(contentsOf: audioSourceURL, encoding: .utf8)
            .components(separatedBy: "\n")
        guard let start = lines.firstIndex(of: "    public func stop() {") else {
            return XCTFail("Could not find Audio.stop() — update this contract test")
        }
        // Everything up to the closing brace at the declaration's own indent.
        guard let end = lines[(start + 1)...].firstIndex(of: "    }") else {
            return XCTFail("Could not find the end of Audio.stop()")
        }
        let body = lines[(start + 1)..<end].joined(separator: "\n")

        guard let arm = body.range(of: "beginFinishing()"),
              let bump = body.range(of: "beginRecordingSessionGeneration()") else {
            return XCTFail(
                "Audio.stop() must arm the system-audio finishing handoff and "
                + "advance the recording generation — one of them is gone"
            )
        }
        XCTAssertTrue(
            arm.upperBound < bump.lowerBound,
            "beginFinishing() must run before the generation advances, or every "
            + "buffer the backend consumer delivers before the asynchronous HAL "
            + "stop is dropped by a closed tail admission"
        )
        XCTAssertTrue(
            body.contains("finishAndDrain()"),
            "Stop must finish-and-drain the system capture; cancel() discards queued PCM"
        )
    }
}
