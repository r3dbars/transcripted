import AVFoundation
import Synchronization
import XCTest
@testable import TranscriptedCore

final class PCMBufferBackpressureGateTests: XCTestCase {
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
}
