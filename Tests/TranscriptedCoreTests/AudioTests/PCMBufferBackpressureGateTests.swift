import AVFoundation
import Synchronization
import XCTest
@testable import TranscriptedCore

final class PCMBufferBackpressureGateTests: XCTestCase {
    private func makeMonoBuffer(frameCount: AVAudioFrameCount = 128) throws -> AVAudioPCMBuffer {
        let format = try XCTUnwrap(
            AVAudioFormat(
                commonFormat: .pcmFormatFloat32,
                sampleRate: 48_000,
                channels: 1,
                interleaved: false
            )
        )
        let buffer = try XCTUnwrap(
            AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frameCount)
        )
        buffer.frameLength = frameCount
        return buffer
    }

    func testMicAndSystemOverflowCanClaimOnlyOneStopPerGeneration() {
        let admission = PCMBackpressureStopAdmission()
        admission.begin(generation: 41)

        XCTAssertTrue(admission.claim(generation: 41))
        for _ in 0..<100_000 {
            XCTAssertFalse(admission.claim(generation: 41))
        }

        admission.begin(generation: 42)
        XCTAssertFalse(admission.claim(generation: 41))
        XCTAssertTrue(admission.claim(generation: 42))
        admission.close(generation: 42)
        XCTAssertFalse(admission.claim(generation: 42))
    }

    func testBacklogNeverExceedsByteLimitAndOverflowTripsOnce() {
        let mebibyte = 1_024 * 1_024
        let gate = PCMBufferBackpressureGate(byteLimit: 8 * mebibyte)
        gate.begin(generation: 7)

        for _ in 0..<8 {
            XCTAssertEqual(gate.admit(bytes: mebibyte, generation: 7), .accepted)
        }
        XCTAssertEqual(gate.pendingBytesForTesting, 8 * mebibyte)
        XCTAssertEqual(gate.admit(bytes: mebibyte, generation: 7), .firstOverflow)

        for _ in 0..<100_000 {
            XCTAssertEqual(gate.admit(bytes: mebibyte, generation: 7), .closed)
        }
        XCTAssertEqual(gate.pendingBytesForTesting, 8 * mebibyte)
    }

    func testOldReservationsRemainAccountedAcrossRecordingGenerations() {
        let gate = PCMBufferBackpressureGate(byteLimit: 100)
        gate.begin(generation: 1)
        XCTAssertEqual(gate.admit(bytes: 60, generation: 1), .accepted)

        gate.begin(generation: 2)
        XCTAssertEqual(gate.admit(bytes: 41, generation: 2), .firstOverflow)
        XCTAssertEqual(gate.pendingBytesForTesting, 60)

        gate.release(bytes: 60)
        gate.begin(generation: 3)
        XCTAssertEqual(gate.admit(bytes: 100, generation: 3), .accepted)
        XCTAssertEqual(gate.pendingBytesForTesting, 100)
    }

    func testConcurrentAdmissionStaysWithinLimitAndTripsOverflowOnce() {
        let gate = PCMBufferBackpressureGate(byteLimit: 128)
        let accepted = Atomic<Int>(0)
        let firstOverflows = Atomic<Int>(0)
        gate.begin(generation: 17)

        DispatchQueue.concurrentPerform(iterations: 10_000) { _ in
            switch gate.admit(bytes: 1, generation: 17) {
            case .accepted:
                _ = accepted.wrappingAdd(1, ordering: .relaxed)
            case .firstOverflow:
                _ = firstOverflows.wrappingAdd(1, ordering: .relaxed)
            case .closed:
                break
            }
        }

        let acceptedCount = accepted.load(ordering: .acquiring)
        XCTAssertLessThanOrEqual(acceptedCount, 128)
        XCTAssertEqual(gate.pendingBytesForTesting, acceptedCount)
        XCTAssertEqual(firstOverflows.load(ordering: .acquiring), 1)
    }

    func testClosedAndStaleGenerationsCannotQueueBuffers() {
        let gate = PCMBufferBackpressureGate(byteLimit: 100)
        gate.begin(generation: 4)

        XCTAssertEqual(gate.admit(bytes: 1, generation: 3), .closed)
        gate.close(generation: 4)
        XCTAssertEqual(gate.admit(bytes: 1, generation: 4), .closed)
        XCTAssertEqual(gate.pendingBytesForTesting, 0)
    }

    func testFinishingGenerationKeepsAdmittingItsTailUntilClosed() {
        let gate = PCMBufferBackpressureGate(byteLimit: 100)
        gate.begin(generation: 5)
        XCTAssertEqual(gate.admit(bytes: 10, generation: 5), .accepted)

        gate.beginFinishing(generation: 5)
        XCTAssertTrue(gate.isFinishing(generation: 5))
        XCTAssertEqual(gate.admit(bytes: 10, generation: 5), .accepted)
        XCTAssertEqual(gate.admit(bytes: 10, generation: 4), .closed)
        XCTAssertEqual(gate.pendingBytesForTesting, 20)

        gate.close(generation: 5)
        XCTAssertFalse(gate.isFinishing(generation: 5))
        XCTAssertEqual(gate.admit(bytes: 10, generation: 5), .closed)
        XCTAssertEqual(gate.pendingBytesForTesting, 20)
    }

    func testOnlyAnOpenGenerationCanStartFinishing() {
        let gate = PCMBufferBackpressureGate(byteLimit: 10)

        gate.begin(generation: 1)
        gate.close(generation: 1)
        gate.beginFinishing(generation: 1)
        XCTAssertFalse(gate.isFinishing(generation: 1), "a closed generation must stay closed")
        XCTAssertEqual(gate.admit(bytes: 1, generation: 1), .closed)

        gate.begin(generation: 2)
        XCTAssertEqual(gate.admit(bytes: 11, generation: 2), .firstOverflow)
        gate.beginFinishing(generation: 2)
        XCTAssertFalse(gate.isFinishing(generation: 2), "an overflowed generation must stay failed")
        XCTAssertEqual(gate.admit(bytes: 1, generation: 2), .closed)

        gate.begin(generation: 3)
        gate.beginFinishing(generation: 2)
        XCTAssertFalse(gate.isFinishing(generation: 2), "a stale stop must not touch the successor")
        XCTAssertEqual(gate.admit(bytes: 1, generation: 3), .accepted)

        // A successor's begin replaces a predecessor still finishing its tail.
        gate.beginFinishing(generation: 3)
        gate.begin(generation: 4)
        XCTAssertFalse(gate.isFinishing(generation: 3))
        XCTAssertEqual(gate.admit(bytes: 1, generation: 3), .closed)
        gate.close(generation: 3)
        XCTAssertEqual(gate.admit(bytes: 1, generation: 4), .accepted)
    }

    func testOverflowWhileFinishingDropsTheTailWithoutRequestingAnotherStop() {
        let gate = PCMBufferBackpressureGate(byteLimit: 10)
        gate.begin(generation: 6)
        XCTAssertEqual(gate.admit(bytes: 8, generation: 6), .accepted)
        gate.beginFinishing(generation: 6)

        XCTAssertEqual(
            gate.admit(bytes: 8, generation: 6),
            .closed,
            "the recording is already stopping; overflow must not report firstOverflow"
        )
        XCTAssertFalse(gate.isFinishing(generation: 6))
        XCTAssertEqual(gate.admit(bytes: 1, generation: 6), .closed)
        XCTAssertEqual(gate.pendingBytesForTesting, 8)
    }

    func testRetainedByteCountIncludesEveryChannelBuffer() throws {
        let format = try XCTUnwrap(
            AVAudioFormat(
                commonFormat: .pcmFormatFloat32,
                sampleRate: 48_000,
                channels: 2,
                interleaved: false
            )
        )
        let buffer = try XCTUnwrap(
            AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 128)
        )
        buffer.frameLength = 128

        XCTAssertEqual(
            PCMBufferBackpressureGate.retainedByteCount(for: buffer),
            128 * 2 * MemoryLayout<Float>.size
        )
    }

    func testHostFanoutIsBoundedAndCloseWaitsForAdmittedTail() throws {
        let buffer = try makeMonoBuffer()
        let retainedBytes = PCMBufferBackpressureGate.retainedByteCount(for: buffer)
        let fanout = BoundedPCMBufferFanout(
            label: "PCMBufferBackpressureGateTests.host-fanout",
            byteLimit: retainedBytes * 2
        )
        let handlerStarted = DispatchSemaphore(value: 0)
        let releaseHandler = DispatchSemaphore(value: 0)
        let tailClosed = DispatchSemaphore(value: 0)
        let handled = Atomic<Int>(0)
        fanout.begin(generation: 9)

        let handler: BoundedPCMBufferFanout.Handler = { _ in
            _ = handled.wrappingAdd(1, ordering: .relaxed)
            handlerStarted.signal()
            _ = releaseHandler.wait(timeout: .now() + 2)
        }

        XCTAssertEqual(fanout.enqueue(buffer, generation: 9, handler: handler), .accepted)
        XCTAssertEqual(handlerStarted.wait(timeout: .now() + 1), .success)
        XCTAssertEqual(fanout.enqueue(buffer, generation: 9, handler: handler), .accepted)
        XCTAssertEqual(fanout.enqueue(buffer, generation: 9, handler: handler), .firstOverflow)
        XCTAssertEqual(fanout.pendingBytesForTesting, retainedBytes * 2)

        fanout.close(generation: 9) {
            tailClosed.signal()
        }
        XCTAssertEqual(
            tailClosed.wait(timeout: .now() + 0.05),
            .timedOut,
            "close must stay behind callbacks already admitted for the generation"
        )

        releaseHandler.signal()
        XCTAssertEqual(handlerStarted.wait(timeout: .now() + 1), .success)
        releaseHandler.signal()
        XCTAssertEqual(tailClosed.wait(timeout: .now() + 1), .success)
        XCTAssertEqual(handled.load(ordering: .acquiring), 2)
        XCTAssertEqual(fanout.pendingBytesForTesting, 0)
        XCTAssertEqual(fanout.enqueue(buffer, generation: 9, handler: handler), .closed)
    }
}
